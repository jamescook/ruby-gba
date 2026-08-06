# frozen_string_literal: true

# Shard the test suite across processes for `rake test:parallel`, and report the
# whole thing as if it were one serial run.
#
# Threads would be the cheaper option, and they aren't useless here — gemba-core
# releases the GVL around run_frame (see rb_thread_call_without_gvl in
# gemba_core_ext.c), so the emulator-backed test files genuinely overlap under a
# thread pool. But the rest of the suite — IR lowering, the cost model, the
# assembler — is pure Ruby and would still crawl one test at a time. So:
# processes. They parallelize all of it, and hand each shard a clean slate, with
# no shared constants and no shared emulator core.
#
# The output problem processes normally create is N runs' worth of banners, dot
# streams and summaries stapled together. The fix is to stop letting the
# children print at all: each installs a reporter that streams structured
# records back over fd 3, and the parent renders one dot stream, one numbered
# failure list, one summary. Anything a child writes to stdout or stderr on its
# own — a stray puts, a segfault in libmgba — is captured separately and shown
# only when there's something to show.
#
# This file is both halves: required by the Rakefile for the parent side, run as
# a script for the child side.

require "etc"
require "json"
require "rbconfig"

module ParallelTest
  CONTROL_FD = 3
  SHARD_SCRIPT = File.expand_path(__FILE__)
  COUNTERS = %w[runs assertions failures errors skips].freeze
  CODE_COUNTER = { "F" => "failures", "E" => "errors", "S" => "skips" }.freeze

  module_function

  # ------------------------------------------------------------------
  # Parent
  # ------------------------------------------------------------------

  def run(files, workers: nil, seed: nil, libs: %w[test lib])
    workers = Integer(workers || ENV["JOBS"] || Etc.nprocessors)
    # One seed for the whole run, so anything that fails in parallel is
    # reproducible with a plain serial rake test.
    seed = Integer(seed || ENV["SEED"] || rand(0xFFFF))
    shards = shard(files, [workers, files.size].min)

    puts "Running #{files.size} test files in #{shards.size} processes (seed #{seed})\n\n"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    children = shards.each_with_index.map { |shard, i| spawn_shard(shard, i + 1, seed, libs) }
    pump children
    puts # close off the dot stream
    report children, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, seed
  end

  # Greedy longest-first bin packing, weighted by file size. File size is a crude
  # stand-in for runtime, but it costs six lines and avoids round-robin's worst
  # case, where the four slowest files all land in the same worker.
  def shard(files, count)
    shards  = Array.new(count) { [] }
    weights = Array.new(count, 0)
    files.sort_by { |file| -File.size(file) }.each do |file|
      lightest = weights.index(weights.min)
      shards[lightest] << file
      weights[lightest] += File.size(file)
    end
    shards.reject(&:empty?)
  end

  # fd 3 carries the structured record stream; stdout and stderr carry whatever
  # the tests themselves decided to print, which we keep out of the way.
  def spawn_shard(files, index, seed, libs)
    control_r, control_w = IO.pipe
    output_r, output_w = IO.pipe

    pid = Process.spawn(
      { "SHARD_FILES" => files.join("\n") },
      RbConfig.ruby, *libs.map { |lib| "-I#{lib}" }, SHARD_SCRIPT, "--seed", seed.to_s,
      CONTROL_FD => control_w, out: output_w, err: output_w
    )
    [control_w, output_w].each(&:close)

    { pid: pid, index: index, files: files.size, control: control_r, output: output_r,
      buffer: +"", stray: +"", results: [], totals: nil }
  end

  # One select loop over every child's two pipes. Progress characters are echoed
  # the moment they arrive, so the dot stream is live and reads like a single
  # run, while everything else is held back until the end.
  def pump(children)
    open = {}
    children.each do |child|
      open[child[:control]] = [child, :control]
      open[child[:output]]  = [child, :output]
    end

    until open.empty?
      ready, = IO.select(open.keys)
      ready.each do |io|
        child, kind = open[io]
        begin
          chunk = io.read_nonblock 4096
        rescue EOFError
          io.close
          open.delete io
          next
        end

        if kind == :output
          child[:stray] << chunk
        else
          child[:buffer] << chunk
          consume_records child
        end
      end
    end

    children.each { |child| child[:status] = Process.waitpid2(child[:pid]).last }
  end

  # Records are one per line: P + progress character, R + a JSON'd result, Z +
  # the shard's final tallies. A partial line just stays in the buffer.
  def consume_records(child)
    while (newline = child[:buffer].index("\n"))
      line = child[:buffer].slice!(0..newline).chomp
      case line[0]
      when "P" then print line[1..]; $stdout.flush
      when "R" then child[:results] << JSON.parse(line[1..])
      when "Z" then child[:totals] = JSON.parse(line[1..])
      end
    end
  end

  def report(children, elapsed, seed)
    totals = Hash.new(0)
    children.each { |child| (child[:totals] || {}).each { |key, n| totals[key] += n } }

    show_skips = ENV["SHOW_SKIPS"] == "1"
    results = children.flat_map { |child| child[:results] }
    results.reject! { |result| result["code"] == "S" } unless show_skips
    results.each_with_index { |result, i| puts format("\n%3d) %s", i + 1, result["text"]) }

    puts format("\nFinished in %.2fs across %d processes", elapsed, children.size)
    puts format("%d runs, %d assertions, %d failures, %d errors, %d skips",
                *COUNTERS.map { |key| totals[key] })
    puts "\nYou have skipped tests. Run with SHOW_SKIPS=1 for details." if
      totals["skips"] > 0 && !show_skips

    report_stray children
    $stdout.flush # abort writes to stderr; don't let it outrun the buffered report
    return if children.all? { |child| child[:status].success? }

    failed = children.reject { |child| child[:status].success? }.map { |child| child[:index] }
    abort "\nFailing shards: #{failed.join(', ')} — reproduce serially with " \
          "`rake test TESTOPTS=\"--seed #{seed}\"`"
  end

  # A shard that never sent its tallies didn't finish — a load error, or the
  # emulator taking the process down with it. Its tests are missing from the
  # counts above, which is exactly why this is loud. It's also the one case
  # where the raw child output explains anything, so it's printed in full
  # rather than tidied away.
  def report_stray(children)
    children.reject { |child| child[:totals] }.each do |child|
      status = child[:status]
      how = status.signaled? ? "killed by SIG#{Signal.signame(status.termsig)}" : "exit #{status.exitstatus}"
      puts "\n--- shard #{child[:index]} died without reporting: #{how} " \
           "(#{child[:files]} files, its tests are missing from the counts above) ---"
      puts child[:stray]
    end

    noisy = children.select { |child| child[:totals] && !child[:stray].strip.empty? }
    return if noisy.empty?

    puts "\n--- output printed by the tests themselves ---"
    noisy.each { |child| print child[:stray] }
  end

  # ------------------------------------------------------------------
  # Child
  # ------------------------------------------------------------------

  # Requires only this shard's slice of the suite, then swaps minitest's
  # reporters for one that talks to the parent. minitest/autorun's at_exit hook
  # does the actual running, so this only has to be in place before it fires.
  def shard_main
    control = IO.new CONTROL_FD
    control.sync = true

    ENV.fetch("SHARD_FILES").split("\n").each { |file| require File.expand_path(file) }

    # Minitest.run builds its reporters, assigns them, then calls every
    # registered extension precisely so plugins can pull them back out. The only
    # non-standard part is registering by name instead of being discovered as a
    # gem named minitest/*_plugin.rb.
    Minitest.extensions << "shard"
    Minitest.define_singleton_method :plugin_shard_init do |_options|
      reporter.reporters.clear
      reporter << ShardReporter.new(control)
    end
  end
end

if $PROGRAM_NAME == ParallelTest::SHARD_SCRIPT
  require "minitest"

  # Minitest has already rendered each failure into its final form by the time a
  # reporter sees it (Result#to_s), so the parent never needs to know anything
  # about assertions or backtraces — it just renumbers strings.
  class ParallelTest::ShardReporter < Minitest::AbstractReporter
    def initialize(control)
      super()
      @control = control
      @totals = Hash.new(0)
      @unfinished = []
    end

    def record(result)
      synchronize do
        @totals["runs"] += 1
        @totals["assertions"] += result.assertions
        code = result.result_code
        @totals[ParallelTest::CODE_COUNTER[code]] += 1 if ParallelTest::CODE_COUNTER.key?(code)

        emit "P", code
        next if result.passed? && !result.skipped?

        @unfinished << result
        emit "R", JSON.generate("code" => code, "text" => result.to_s)
      end
    end

    def report
      ParallelTest::COUNTERS.each { |key| @totals[key] += 0 } # ensure every key exists
      emit "Z", JSON.generate(@totals)
    end

    # Same rule minitest's own StatisticsReporter uses: skips don't fail a run.
    def passed?
      @unfinished.all?(&:skipped?)
    end

    private

    def emit(tag, payload)
      @control.write "#{tag}#{payload}\n"
    end
  end

  ParallelTest.shard_main
end
