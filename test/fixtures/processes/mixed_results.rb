# frozen_string_literal: true

require "test_helper"

# A small suite for test/vblank/testing/test_processes.rb to run across processes: tests that pass,
# one that fails, and skips for two reasons. Not named test_*.rb, so the suite itself never loads
# it.
#
# Each test leaves a file named for the process that ran it in the folder PROCESSES_FIXTURE_PIDS
# names, holding the seed that process was given, so the test of the runner can see the work was
# spread and every process had the run's one seed. With PROCESSES_FIXTURE_DIE set, one test takes
# its own process down.
module ProcessesFixture
  def note_process
    folder = ENV.fetch("PROCESSES_FIXTURE_PIDS", nil)
    File.write(File.join(folder, "#{Process.pid}-#{name}"), Minitest.seed.to_s) if folder
  end
end

class ProcessesFixturePasses < Minitest::Test
  include ProcessesFixture

  12.times do |i|
    define_method(:"test_passes_#{i}") do
      note_process
      sleep 0.05
      assert true
    end
  end

  def test_dies_when_asked
    note_process
    Process.kill(:KILL, Process.pid) if ENV["PROCESSES_FIXTURE_DIE"]
    assert true
  end

  # An error of a kind only the process that played the test ever declared, as one from a file
  # only that test required would be: the process that reports the run cannot rebuild it.
  def test_raises_what_only_its_process_knows_when_asked
    note_process
    return assert(true) unless ENV["PROCESSES_FIXTURE_STRANGE_ERROR"]

    Object.const_set(:ProcessesFixtureStrangeError, Class.new(StandardError)) unless defined?(ProcessesFixtureStrangeError)
    raise ProcessesFixtureStrangeError, "a message worth keeping"
  end
end

class ProcessesFixtureMixed < Minitest::Test
  include ProcessesFixture

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
