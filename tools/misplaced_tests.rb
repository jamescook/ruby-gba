#!/usr/bin/env ruby
# frozen_string_literal: true

# TESTS KEPT OUT OF test/all/ THAT WOULD PLAY THERE.
#
#   ruby tools/misplaced_tests.rb                    every folder, on every run that does not load it
#   rake test:misplaced ONLY=test/console/gba RUNS=gbc,snes
#
# A test lives in test/all/ unless a run that cannot do what it asks fails it there (see
# test/support/suites.rb). A test in a console's or a lowering's folder can outlive the reason it
# was moved: the console gains the feature, the lowering learns to answer, or the test never
# needed to leave. This plays each file of every folder but test/all/ on each run that does not
# load it, and names every test that passed there while playing a game through the run's player
# (`game_player`) — a test of a lowering's own output passes anywhere and plays nothing, so it is
# not named. A test named for every run it was tried on belongs in test/all/; one named for some
# runs may belong in a console's folder those runs share.
#
# Each file is played in a process of its own, a run's setting given as VBLANK_LOWERING, as many
# at once as the computer has cores. It is slow, which is why it is a tool and not part of the
# suite.
require "etc"
require "open3"
require_relative "../lib/vblank/testing/lowering"
require_relative "../test/support/suites"

ROOT = File.expand_path("..", __dir__)
PLAYED = File.join(__dir__, "misplaced_tests", "played.rb")

runs = (ENV["RUNS"]&.split(",")&.map(&:to_sym) || VBlank::Testing::Lowering::NAMES)
only = ENV["ONLY"]
every = TestSuites.all_files.reject { |path| path.start_with?("#{TestSuites::ALL_DIR}/") }
every = every.select { |path| path.start_with?(only) } if only

jobs = runs.flat_map do |run|
  loaded = VBlank::Testing::Lowering.files_for(run, files: TestSuites.all_files, folders: TestSuites::LOWERING_FOLDERS)
  (every - loaded).map { |path| [run, path] }
end
puts "Playing #{jobs.size} files on runs that do not load them, #{Etc.nprocessors} at a time."

found = Hash.new { |hash, test| hash[test] = [] }
queue = Queue.new
jobs.each { |job| queue << job }
lock = Mutex.new
Array.new(Etc.nprocessors) do
  Thread.new do
    while (job = begin
      queue.pop(true)
    rescue ThreadError
      nil
    end)
      run, path = job
      out, = Open3.capture2e({ "VBLANK_LOWERING" => run.to_s }, "bundle", "exec", "ruby", "-Ilib", "-Itest",
                             "-r#{PLAYED}", path, chdir: ROOT)
      played = out.lines.filter_map { |line| line[/\APLAYED (\S+)/, 1] }
      lock.synchronize { played.each { |test| found["#{path}  #{test}"] << run } }
    end
  end
end.each(&:join)

if found.empty?
  puts "Every test kept out of test/all/ fails, or plays no game, on the runs that do not load it."
else
  puts "Passed while playing a game on a run that does not load it (a candidate for test/all/, or for a console's folder):"
  found.sort.each { |test, on| puts "  #{test}  — #{on.sort.join(', ')}" }
end
