# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# THE NATIVE RUN SPREADS ITS TESTS OVER PROCESSES, and has to report them as one run: the same
# totals, the same failures, the same skips by reason and the same class counts as one process
# playing every test itself. Each case runs a small fixture suite both ways and compares what
# they print.
class TestParallelTest < Minitest::Test
  # Starts child processes, which Ruby cannot do from inside a Ractor — the spawn waits for
  # ever — so on the main Ractor, not in the pool. See test_helper.
  runs_on_the_main_ractor!

  ROOT = RubyGBA.root.to_s
  FIXTURE = File.join(ROOT, "test/fixtures/parallel_test/mixed_results.rb")
  RUNNER = File.join(ROOT, "tools/parallel_test.rb")

  # Rake's own loader, which `rake test:lowering:native` starts the suite with: it takes every argument
  # that does not start with a dash for a file to load.
  LOADER = File.join(Gem::Specification.find_by_name("rake").full_gem_path, "lib/rake/rake_test_loader.rb")

  # The fixture suite played the way `rake test:lowering:native` plays the suite: by one process when
  # +processes+ is nil, else by that many. What it printed, and whether it passed.
  private def run_fixture(processes: nil, env: {}, seed: 7)
    command = [RbConfig.ruby, "-rbundler/setup", "-Itest", "-Ilib"]
    command << "-r#{RUNNER}" if processes
    command += [LOADER, FIXTURE, "--no-ractor"]
    command << "--seed=#{seed}" if seed
    settings = { "RUBY_GBA_LOWERING" => "native", "MT_CPU" => "1", "TEST_PROCESSES" => processes&.to_s }
    out, status = Open3.capture2e(settings.merge(env), *command, chdir: ROOT)
    [out, status.success?]
  end

  # Everything a run prints from the end of its timing line on: the failures, the totals, and
  # what the suite's own reporters say about skips.
  private def report_of(out)
    out[/^Finished in .*?\n(.*)\z/m, 1] or flunk("the run printed no report:\n#{out}")
  end

  def test_a_run_across_processes_reports_what_one_process_reports
    alone, alone_passed = run_fixture
    spread, spread_passed = run_fixture(processes: 2)

    assert_equal report_of(alone), report_of(spread)
    assert_match(/18 runs, \d+ assertions, 1 failures, 0 errors, 3 skips/, report_of(spread))
    refute alone_passed
    refute spread_passed, "a run with a failure has to fail across processes too"
  end

  # Each test the native run plays leaves a file named for the process that played it.
  private def processes_that_played(processes, env = {}, seed: 7)
    Dir.mktmpdir do |folder|
      out, = run_fixture(processes: processes, env: env.merge("PARALLEL_FIXTURE_PIDS" => folder), seed: seed)
      played = Dir.children(folder)
      seeds = played.map { |file| File.read(File.join(folder, file)) }.uniq
      [out, played.size, played.map { |file| file.split("-").first }.uniq.size, seeds]
    end
  end

  # One seed for the run, the one it prints, so a test that rolls random numbers can be played
  # again — including when the run picked the seed itself.
  def test_every_process_plays_with_the_seed_the_run_prints
    out, _, processes, seeds = processes_that_played(3, seed: nil)

    assert_operator processes, :>, 1
    assert_equal [out[/--seed (\d+)/, 1]], seeds
  end

  def test_the_tests_are_played_in_more_than_one_process
    _, tests, processes = processes_that_played(3)

    assert_equal 18, tests
    assert_operator processes, :>, 1
  end

  # A process that dies under a test costs that test, said as an error; a new process takes
  # its place, and every other test is still played. One process, so nobody else would.
  def test_a_process_that_dies_costs_only_the_test_it_was_playing
    out, tests, = processes_that_played(1, { "PARALLEL_FIXTURE_DIE" => "1" })

    assert_equal 18, tests
    assert_match(/18 runs, \d+ assertions, 1 failures, 1 errors, 3 skips/, out)
    assert_match(/ParallelFixturePasses#test_dies_when_asked:\nRuntimeError: .*killed by SIGKILL/, out)
  end

  # A result the reporting process cannot rebuild is still an error of that test, and keeps the
  # message the test failed with.
  def test_an_error_only_the_playing_process_knows_keeps_its_message
    out, = run_fixture(processes: 2, env: { "PARALLEL_FIXTURE_STRANGE_ERROR" => "1" })

    assert_match(/ParallelFixturePasses#test_raises_what_only_its_process_knows_when_asked:\n.*could not be read back/, out)
    assert_includes out, "ParallelFixtureStrangeError: a message worth keeping"
  end
end
