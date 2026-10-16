# frozen_string_literal: true

require "etc"
require "rake"
require "rake/tasklib"
require "rake/testtask"
require_relative "lowering"

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
    # That defines three tasks:
    #
    #   rake test                    every lowering, one after the other, ending with a line each
    #   rake test:lowering:gba       the game on the interpreter, which the cartridge is checked against
    #   rake test:lowering:native    the game built as C, checked against the interpreter (needs zig)
    #
    # Each takes TEST= for one file, and `rake test` plays it on each lowering whose run loads it.
    #
    # The GBA lowering's run is a plain test run, so a suite that puts its tests in Ractors
    # (--ractor in TESTOPTS) keeps doing so there. The native lowering's run cannot: every test
    # starts zig and the program it builds, which Ruby cannot do from inside a Ractor. So that run
    # is always plain minitest's, and spreads its tests over several processes instead (see
    # Processes) — TEST_PROCESSES of them, or as many as the Ractor run has workers, or half the
    # machine's cores. The two runs go one after the other so they never compete for a core.
    #
    # A test about one lowering's own output — the C the game is built as, say — goes in a folder
    # that lowering owns, and the other lowering's run never loads it:
    # `t.lowering_folders = { native: ["test/native"] }`. Every other test plays on both.
    class RakeTasks < Rake::TaskLib
      # What `rake test` calls each lowering's run in the lines it ends with, in the order it plays them.
      LABELS = { gba: "GBA lowering", native: "native lowering" }.freeze
      OUTCOMES = { passed: "passed", failed: "FAILED", not_played: "does not play this file" }.freeze

      # The folders a test file can require from by bare name: the game's own code and its tests.
      LIBS = %w[lib test].freeze

      # What the native lowering's run changes about how the tests are played, put back as they
      # were given for the GBA lowering's run whichever of the two goes first.
      PLAYING_SETTINGS = %w[TESTOPTS MT_RACTOR MT_CPU].freeze

      # The test files, and the folders each lowering owns.
      attr_accessor :test_files, :lowering_folders

      def initialize
        super
        @test_files = Rake::FileList["test/**/test_*.rb"]
        @lowering_folders = {}
        @given = ENV.to_h.slice(*PLAYING_SETTINGS)
        yield self if block_given?
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
          results = LABELS.map { |lowering, label| run_lowering(lowering, label) }
          puts
          results.each do |label, outcome, seconds|
            puts format("%-16s %s%s", label, OUTCOMES.fetch(outcome), outcome == :not_played ? "" : format(" in %ds", seconds))
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

      def define_lowering_tasks
        namespace :test do
          namespace :lowering do
            define_settings_tasks
            define_zig_task

            Rake::TestTask.new(gba: :gba_settings) do |t|
              t.libs = LIBS.dup
              t.test_files = files(:gba)
              t.description = "Run the tests on the GBA lowering: the game on the interpreter (one file with TEST=)"
            end

            Rake::TestTask.new(native: %i[zig native_settings]) do |t|
              t.libs = LIBS.dup
              t.ruby_opts << "-r#{File.expand_path('processes.rb', __dir__)}"
              t.test_files = files(:native)
              t.description = "Run the tests on the native lowering: the game built as C, checked against " \
                              "the interpreter (needs zig; one file with TEST=)"
            end
          end
        end
      end

      # WHAT EACH RUN SAYS ABOUT ITSELF, which every test reads (Testing.lowering). The native run
      # is also plain minitest's whatever the caller said about Ractors — the Ractor runner's flag
      # and its setting are both taken away, and a suite with no Ractor runner had neither — and
      # plays one test at a time in each of its processes. The GBA lowering's run puts all of that
      # back as it was given, so a rake call that plays the native run first does not hand the
      # GBA run its settings.
      def define_settings_tasks
        task :gba_settings do
          PLAYING_SETTINGS.each { |name| ENV[name] = @given[name] }
          ENV[Lowering::SETTING] = "gba"
        end

        task :native_settings do
          ENV["TESTOPTS"] = (ENV.fetch("TESTOPTS", "").split - %w[--ractor]).join(" ")
          ENV.delete("MT_RACTOR")
          ENV["TEST_PROCESSES"] ||= ENV.fetch("MT_RACTOR_WORKERS") { [Etc.nprocessors / 2, 1].max.to_s }
          ENV["MT_CPU"] = "1"
          ENV[Lowering::SETTING] = "native"
        end
      end

      # The native lowering's run compiles C, so it needs zig (the version the backend is written
      # against), and a missing or wrong zig stops it here with one plain line rather than failing
      # every test in turn.
      def define_zig_task
        task :zig do
          require_relative "../root"
          require_relative "../ir/backends/native/zig"
          IR::Backends::Native::Zig.version
        rescue IR::Backends::Native::Zig::Error => e
          abort "The native lowering's run needs zig, and #{e.message}"
        end
      end
    end
  end
end
