# frozen_string_literal: true

require "rake"
require "rake/tasklib"
require_relative "../console/description"
require_relative "../console/kit" # which names its parts and loads none of them
require_relative "lowering"
require_relative "test_task"

module RubyGBA
  module Testing
    # A GAME'S RAKE TASKS FOR ITS OWN TESTS, one run for each lowering. In the game's Rakefile:
    #
    #   require "ruby_gba/testing/rake_tasks"
    #
    #   RubyGBA::Testing::RakeTasks.new do |t|
    #     t.test_files = FileList["test/**/test_*.rb"]   # the default
    #   end
    #
    # That defines four tasks:
    #
    #   rake test                    every lowering, one after the other, ending with a line each
    #   rake test:lowering:gba       the game on the interpreter, which the cartridge is checked against
    #   rake test:lowering:native    the game built as C, checked against the interpreter (needs zig)
    #   rake test:lowering:js        the game built as JavaScript, checked the same way (needs node)
    #
    # Each takes TEST= for one file, and `rake test` plays it on each lowering whose run loads it.
    #
    # A game for the Game Boy Color too says so here as it does where the game is named:
    # `t.consoles = %i[gba gbc]`. That adds a fifth task, `rake test:lowering:gbc`, the game built
    # as a Color cartridge and checked against the interpreter, and `rake test` plays it too. A game
    # that says nothing is for the Advance alone, and gets no Color run it could never pass. The
    # Rakefile cannot see which games its tests build, so it is told the same list the games are,
    # and it takes and refuses exactly what `consoles:` does.
    #
    # The GBA lowering's run is a plain test run, so a suite that puts its tests in Ractors
    # (--ractor in TESTOPTS) keeps doing so there. The native lowering's run cannot, and spreads
    # its tests over several processes instead (TestTask says how). The two runs go one after the
    # other so they never compete for a core.
    #
    # A test about one lowering's own output — the C the game is built as, say — goes in a folder
    # that lowering owns, and the other lowering's run never loads it:
    # `t.lowering_folders = { native: ["test/native"] }`. Every other test plays on both.
    #
    # A game whose Rakefile keeps its own rake test, or a task for each group of its tests, does
    # not want this whole set: it makes the runs it wants out of TestTask, which defines nothing
    # but the task it is asked for.
    class RakeTasks < Rake::TaskLib
      # What `rake test` calls each lowering's run in the lines it ends with, in the order it plays them.
      LABELS = Lowering::TITLES.transform_values { |title| "#{title} lowering" }.freeze
      OUTCOMES = { passed: "passed", failed: "FAILED", not_played: "does not play this file" }.freeze

      # The test files; the folders a test file can require from by bare name (the game's own code
      # and its tests, lib and test unless told); the folders each lowering owns; and the consoles
      # the game is for, the Advance alone unless told.
      attr_accessor :test_files, :libs, :lowering_folders, :consoles

      def initialize
        super
        @test_files = Rake::FileList["test/**/test_*.rb"]
        @libs = %w[lib test]
        @lowering_folders = {}
        @consoles = [Console::DEFAULT]
        yield self if block_given?
        @lowerings = Lowering.lowerings_for(Console.refuse_unknown_consoles!(consoles, setting: "t.consoles"))
        define_lowering_tasks
        define_test_task
      end

      # The test files +lowering+'s run loads.
      def files(lowering)
        Lowering.files_for(lowering, files: test_files.to_a, folders: lowering_folders)
      end

      private

      def define_test_task
        desc "Run the tests on every lowering, one after the other (one file with TEST=test/test_foo.rb)"
        task :test do
          labels = LABELS.slice(*@lowerings)
          results = labels.map { |lowering, label| run_lowering(lowering, label) }
          puts
          results.each do |label, outcome, seconds|
            puts format("%-*s %s%s", labels.values.map(&:length).max, label, OUTCOMES.fetch(outcome),
                        outcome == :not_played ? "" : format(" in %ds", seconds))
          end
          abort "rake test: a lowering's run failed" if results.any? { |_, outcome| outcome == :failed }
        end
      end

      # One lowering's run, inside `rake test`: whether it passed and how long it took. Every one
      # is played whatever the one before found.
      def run_lowering(lowering, label)
        named = ENV["TEST"]&.delete_prefix("./")
        return [label, :not_played, 0] if named && !files(lowering).include?(named)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        passed = begin
          Rake::Task["test:lowering:#{lowering}"].invoke
          true
        rescue RuntimeError # a test task whose tests failed says so by raising
          false
        end
        [label, passed ? :passed : :failed, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
      end

      # Each lowering's run is a TestTask, which says how a run for that lowering is played: one for
      # each of Lowering::NAMES that plays the game's consoles, so a new lowering is a row there and
      # not a task written here.
      def define_lowering_tasks
        namespace :test do
          namespace :lowering do
            @lowerings.each do |lowering|
              TestTask.new(lowering) do |t|
                t.lowering = lowering
                t.libs = libs.dup
                t.test_files = files(lowering)
                needs = Lowering::NEEDS[lowering]&.then { |tool| "needs #{tool}; " }
                t.description = "Run the tests on the #{Lowering::TITLES.fetch(lowering)} lowering: " \
                                "#{Lowering::RUNS.fetch(lowering)} (#{needs}one file with TEST=)"
              end
            end
          end
        end
      end
    end
  end
end
