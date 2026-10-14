# frozen_string_literal: true

require "test_helper"

# A small suite for test/tools/test_parallel_test.rb to run across processes: tests that pass,
# one that fails, skips for two reasons, and a class the native run leaves alone. Not named
# test_*.rb, so the suite itself never loads it.
#
# Each test leaves a file named for the process that ran it in the folder PARALLEL_FIXTURE_PIDS
# names, holding the seed that process was given, so the test of the runner can see the work was
# spread and every process had the run's one seed. With PARALLEL_FIXTURE_DIE set, one test takes
# its own process down.
module ParallelFixture
  def note_process
    folder = ENV.fetch("PARALLEL_FIXTURE_PIDS", nil)
    File.write(File.join(folder, "#{Process.pid}-#{name}"), Minitest.seed.to_s) if folder
  end
end

class ParallelFixturePasses < Minitest::Test
  runs_on :native
  include ParallelFixture

  12.times do |i|
    define_method(:"test_passes_#{i}") do
      note_process
      sleep 0.05
      assert true
    end
  end

  def test_dies_when_asked
    note_process
    Process.kill(:KILL, Process.pid) if ENV["PARALLEL_FIXTURE_DIE"]
    assert true
  end

  # An error of a kind only the process that played the test ever declared, as one from a file
  # only that test required would be: the process that reports the run cannot rebuild it.
  def test_raises_what_only_its_process_knows_when_asked
    note_process
    return assert(true) unless ENV["PARALLEL_FIXTURE_STRANGE_ERROR"]

    Object.const_set(:ParallelFixtureStrangeError, Class.new(StandardError)) unless defined?(ParallelFixtureStrangeError)
    raise ParallelFixtureStrangeError, "a message worth keeping"
  end
end

class ParallelFixtureMixed < Minitest::Test
  runs_on :reference, :native
  include ParallelFixture

  def test_fails
    note_process
    flunk "this one fails on purpose"
  end

  def test_skips_one
    note_process
    skip "cannot yet: the first reason"
  end

  def test_skips_two
    note_process
    skip "cannot yet: the first reason"
  end

  def test_skips_three
    note_process
    skip "cannot yet: the second reason"
  end
end

class ParallelFixtureInterpreterOnly < Minitest::Test
  runs_on :reference

  def test_never_played_on_native = flunk("a native run must not play this")
end
