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
  ROOT = File.expand_path("..", __dir__)
  COUNTERS = %w[runs assertions failures errors skips].freeze
  CODE_COUNTER = { "F" => "failures", "E" => "errors", "S" => "skips" }.freeze

  # Where the previous run's per-file timings live. Gitignored: it changes every
  # run, so committing it would mean a conflicting diff on every merge, and the
  # only thing a fresh clone loses is one poorly-balanced run.
  TIMINGS_FILE = File.join(ROOT, ".test_timings.json")
  TIMINGS_VERSION = 1

  # How much of a new observation to believe. One run where you had a build going
  # in another terminal shouldn't dictate the split for the next week.
  SMOOTHING = 0.6

  module_function

  def relative(path)
    path.to_s.delete_prefix("#{ROOT}/")
  end

  def median(values)
    return 0.0 if values.empty?

    sorted = values.sort
    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end

  # ------------------------------------------------------------------
  # Parent
  # ------------------------------------------------------------------

  def run(files, workers: nil, seed: nil, libs: %w[test lib])
    workers = Integer(workers || ENV["JOBS"] || Etc.nprocessors)
    # One seed for the whole run, so anything that fails in parallel is
    # reproducible with a plain serial rake test.
    seed = Integer(seed || ENV["SEED"] || rand(0xFFFF))
    timings = load_timings
    shards = shard(files, [workers, files.size].min, timings)

    puts "Running #{files.size} test files in #{shards.size} processes " \
         "(seed #{seed}, #{timings ? 'balanced by recorded timings' : 'no timings yet'})\n\n"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    children = shards.each_with_index.map { |shard, i| spawn_shard(shard, i + 1, seed, libs) }
    pump children
    puts # close off the dot stream

    observed = save_timings(children, files, timings)
    report children, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, seed, observed
  end

  # Greedy longest-processing-time-first bin packing: walk the files heaviest to
  # lightest, always dropping the next one into the shard with the least work so
  # far. It's the classic approximation for makespan on identical machines —
  # provably within 4/3 of optimal, and much closer than that in practice once no
  # single file dominates.
  #
  # Only the weight changes between a cold run and a warm one. Cold, it's file
  # size: a weak correlate of runtime, but weakly-informed beats uninformed, and
  # it only governs the single run before timings exist.
  def shard(files, count, timings = nil)
    weight = weigher(files, timings)
    shards  = Array.new(count) { [] }
    weights = Array.new(count, 0.0)
    files.sort_by { |file| -weight.call(file) }.each do |file|
      lightest = weights.index(weights.min)
      shards[lightest] << file
      weights[lightest] += weight.call(file)
    end
    shards.reject(&:empty?)
  end

  # A file we've never timed gets the median of the ones we have — not zero,
  # which would pile every new test file into one shard, and not the max, which
  # would strand a shard idle. The overhead constant covers process boot and the
  # require of the file itself, which no sum of test times can see.
  def weigher(files, timings)
    return ->(file) { File.size(file).to_f } unless timings

    known = timings["files"]
    fallback = median(known.values)
    overhead = timings["overhead"].to_f
    ->(file) { (known[relative(file)] || fallback) + overhead }
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
      buffer: +"", stray: +"", results: [], totals: nil, times: nil,
      spawned_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
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
          # The control pipe hitting EOF means the child is gone, which is the
          # only moment we can measure its wall time — measuring after the loop
          # would give every child the whole run's duration.
          if kind == :control
            child[:wall] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - child[:spawned_at]
          end
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
      when "T" then child[:times] = JSON.parse(line[1..])
      when "Z" then child[:totals] = JSON.parse(line[1..])
      end
    end
  end

  def report(children, elapsed, seed, observed)
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

    report_slowest observed, children.size
    report_stray children
    $stdout.flush # abort writes to stderr; don't let it outrun the buffered report
    return if children.all? { |child| child[:status].success? }

    failed = children.reject { |child| child[:status].success? }.map { |child| child[:index] }
    abort "\nFailing shards: #{failed.join(', ')} — reproduce serially with " \
          "`rake test TESTOPTS=\"--seed #{seed}\"`"
  end

  # Always show where the time went. Once the packing is driven by real numbers,
  # the thing that decides how long a run takes stops being the split and starts
  # being the single slowest file — and that's invisible unless it's printed.
  def report_slowest(observed, workers)
    return if observed.empty?

    ranked = observed.sort_by { |_, time| -time }
    puts "\nSlowest files: " +
         ranked.first(3).map { |file, time| format("%s %.1fs", File.basename(file), time) }.join(", ")

    slowest_file, slowest_time = ranked.first
    ideal = observed.values.sum / workers
    return unless slowest_time > ideal

    puts format("  %s alone sets a %.1fs floor — past that, more workers can't help; " \
                "splitting it would.", slowest_file, slowest_time)
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
  # Timings artifact
  # ------------------------------------------------------------------

  # A timings cache must never be able to break a test run, so anything
  # unreadable, malformed, or from a future format is treated as simply absent.
  def load_timings
    return nil if ENV["NO_TIMINGS"] == "1"

    data = JSON.parse(File.read(TIMINGS_FILE))
    return nil unless data["version"] == TIMINGS_VERSION

    files = data["files"]
    return nil unless files.is_a?(Hash) && !files.empty?

    { "files" => files.transform_values(&:to_f), "overhead" => data["overhead"].to_f }
  rescue Errno::ENOENT, JSON::ParserError, TypeError, NoMethodError
    nil
  end

  # Returns the timings observed this run, whether or not they got persisted —
  # the report needs them either way.
  def save_timings(children, files, previous)
    observed = {}
    children.each { |child| (child[:times] || {}).each { |file, time| observed[file] = time } }
    return observed if ENV["NO_TIMINGS"] == "1" || observed.empty?

    merged = merge_timings(observed, previous, files)
    write_timings merged, observed_overhead(children, previous)
    observed
  end

  # Keep only files that still exist in the suite, so renames and deletions age
  # out. A file the run didn't reach — because its shard died — keeps whatever
  # we knew about it before rather than being dropped.
  def merge_timings(observed, previous, files)
    known = previous ? previous["files"] : {}
    files.each_with_object({}) do |path, merged|
      file = relative(path)
      fresh = observed[file]
      stored = known[file]
      merged[file] =
        if fresh && stored then (SMOOTHING * fresh) + ((1 - SMOOTHING) * stored)
        else fresh || stored
        end
      merged.delete file if merged[file].nil?
    end
  end

  # Summed test times always undercount: they miss process boot and the require
  # of the test files. The gap between a shard's wall time and the work it
  # reported is that cost, and dividing by its file count turns it into a
  # per-file constant the packer can add. Shards that died are excluded — their
  # wall time measures when they crashed, not how long their work takes.
  def observed_overhead(children, previous)
    per_file = children.filter_map do |child|
      next unless child[:times] && child[:wall] && child[:files] > 0

      gap = child[:wall] - child[:times].values.sum
      next if gap <= 0

      gap / child[:files]
    end
    return previous ? previous["overhead"] : 0.0 if per_file.empty?

    fresh = median(per_file)
    previous ? (SMOOTHING * fresh) + ((1 - SMOOTHING) * previous["overhead"]) : fresh
  end

  # Written via a temp file and renamed into place, so an interrupted run can't
  # leave a half-written artifact behind for the next one to choke on.
  def write_timings(files, overhead)
    payload = {
      "version" => TIMINGS_VERSION,
      "overhead" => overhead.round(4),
      "files" => files.sort.to_h { |file, time| [file, time.round(4)] }
    }
    tmp = "#{TIMINGS_FILE}.#{Process.pid}.tmp"
    File.write tmp, "#{JSON.pretty_generate(payload)}\n"
    File.rename tmp, TIMINGS_FILE
  rescue SystemCallError
    # A read-only checkout or a full disk is not a reason to fail the suite.
    File.unlink tmp if tmp && File.exist?(tmp)
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
      @times = Hash.new(0.0)
      @unfinished = []
    end

    def record(result)
      synchronize do
        @totals["runs"] += 1
        @totals["assertions"] += result.assertions
        code = result.result_code
        @totals[ParallelTest::CODE_COUNTER[code]] += 1 if ParallelTest::CODE_COUNTER.key?(code)
        charge result

        emit "P", code
        next if result.passed? && !result.skipped?

        @unfinished << result
        emit "R", JSON.generate("code" => code, "text" => result.to_s)
      end
    end

    def report
      ParallelTest::COUNTERS.each { |key| @totals[key] += 0 } # ensure every key exists
      emit "T", JSON.generate(@times)
      emit "Z", JSON.generate(@totals)
    end

    # Same rule minitest's own StatisticsReporter uses: skips don't fail a run.
    def passed?
      @unfinished.all?(&:skipped?)
    end

    private

    # Bill this test's time to the file that defined it. source_location points
    # at the method definition, so a test generated by a helper is charged to
    # the helper — which is wrong but harmless: the parent only looks up keys it
    # recognises as test files and treats the rest as unknown.
    def charge(result)
      file, = result.source_location
      return unless file && File.absolute_path?(file)

      @times[ParallelTest.relative(file)] += result.time
    end

    def emit(tag, payload)
      @control.write "#{tag}#{payload}\n"
    end
  end

  ParallelTest.shard_main
end
