# frozen_string_literal: true

# THE NATIVE RUN'S TESTS, SPREAD OVER SEVERAL PROCESSES and reported as one run. The native
# lowering's rake task (RakeTasks) loads this beside the test files (ruby -r), and it changes one
# thing about the run: where each test is played.
#
# Why processes. A suite can put each test in a Ractor, which is how one Ruby process uses
# several cores, but a native test starts child processes (zig, and the program it builds) and
# Ruby cannot do that from inside a Ractor. Threads can, and the native run used to put its tests
# on threads — which bought next to nothing, because a native test is nearly all Ruby work
# (lowering the game to C, playing it again on the interpreter, comparing every frame) and
# threads take turns at Ruby work. Separate processes do not.
#
# HOW IT IS ONE RUN. The process rake starts loads every test file and runs minitest as usual:
# its options, its seed, its reporters and the suite's own (the skips by reason). Only the
# playing moves. Where minitest would play the tests one after another, this starts
# TEST_PROCESSES children, each loading the same files, and hands them tests one at a time — the
# next to whichever child asks first, so a slow test holds up one child and not a share of the
# suite. Each child plays the test it is given and sends the result back, and the parent hands
# it to its reporters as if it had played the test itself. So the report is the one a single
# process prints, because it is printed by the same reporters from the same results.
#
# A child that dies part way through a test — a crash in a program it started, a signal — costs
# that test, which is reported as an error naming how the child ended and what it printed, and a
# new child takes its place for the tests still waiting.
#
# Several children build C at the same moment, and nothing has to keep them apart: each build is
# written under a name of its own and renamed into place once whole (Native::Zig), and zig keeps
# its own cache safe to share.
#
# What a child prints is kept, and shown only for a child that died: a single process would let
# a test's own printing through, and a run of many children would interleave it with the dots.
#
# This file is both halves. Loaded in the parent it plays tests through children; loaded in a
# child (TEST_PROCESS_CHILD) it plays the tests the parent sends. A child starts with the
# parent's own command, so it loads the same files the same way.
require "minitest"
require "rbconfig"

module RubyGBA
  module Testing
    module Processes
      PROCESSES_SETTING = "TEST_PROCESSES"
      CHILD_SETTING = "TEST_PROCESS_CHILD"
      RECORDS_FD = 3 # a child's results, and its asks for work, to the parent
      WORK_FD = 4    # the parent's answers: the next test, or the pipe closed when there are none

      # The command this process was started with, taken while ARGV still holds the test files:
      # rake's loader takes them out of ARGV as it loads them. The load paths are the project's
      # own (-Itest -Ilib); the gems come to a child the way they came here, through the
      # environment.
      COMMAND = [$PROGRAM_NAME, *ARGV].freeze
      LOAD_PATHS = $LOAD_PATH.select { |path| path.start_with?(Dir.pwd) }.uniq.freeze

      module_function

      def child? = ENV[CHILD_SETTING] == "1"
      def processes = Integer(ENV.fetch(PROCESSES_SETTING))

      # The parent's command, with the seed it settled on put last, where it wins: a run that was
      # not given one picks its own, after COMMAND was taken. One word, `--seed=N`, because
      # rake's loader takes a word that does not start with a dash for a file to load. Warnings
      # are on in a child when they are on here.
      def child_command
        warnings = $VERBOSE ? ["-w"] : []
        [RbConfig.ruby, *warnings, *LOAD_PATHS.map { |path| "-I#{path}" }, "-r#{__FILE__}", *COMMAND,
         "--seed=#{Minitest.seed}"]
      end

      # --- the parent ---

      # In place of minitest's own: the same tests, in the same order, played by children.
      module PlayInChildren
        def run_all_suites(reporter, options)
          tests = Minitest::Runnable.runnables.shuffle.flat_map do |klass|
            klass.filter_runnable_methods(options).map { |name| [klass, name] }
          end
          Children.new(tests, reporter, options).play
        end
      end

      # The children and the tests waiting for them.
      class Children
        Child = Struct.new(:pid, :records, :work, :output, :buffer, :printed, :playing, :asked_for_work)

        def initialize(tests, reporter, options)
          @waiting = tests
          @reporter = reporter
          @options = options
          @children = []
        end

        def play
          count = [Processes.processes, @waiting.size].min
          if count.positive?
            @options[:io].puts "Playing #{@waiting.size} #{@waiting.size == 1 ? 'test' : 'tests'} in " \
                               "#{count} #{count == 1 ? 'process' : 'processes'}"
          end
          count.times { start_child }
          read_children until @children.empty?
        ensure
          @children.each { |child| stop(child) }
        end

        private

        def start_child
          records_r, records_w = IO.pipe
          work_r, work_w = IO.pipe
          output_r, output_w = IO.pipe
          pid = Process.spawn({ CHILD_SETTING => "1" }, *Processes.child_command,
                              RECORDS_FD => records_w, WORK_FD => work_r, out: output_w, err: output_w)
          [records_w, work_r, output_w].each(&:close)
          work_w.sync = true
          @children << Child.new(pid, records_r, work_w, output_r, +"", +"", nil, false)
        end

        def read_children
          pipes = @children.flat_map { |child| [child.records, child.output].reject(&:closed?) }
          IO.select(pipes).first.each do |pipe|
            child = @children.find { |c| c.records == pipe || c.output == pipe }
            next if child.nil? || pipe.closed? # its child finished earlier in this same pass

            pipe == child.output ? read_output(child) : read_records(child)
          end
        end

        # What a child prints is kept, and shown only when it died: a test that prints something
        # on its own is not the run's business.
        def read_output(child)
          child.printed << child.output.read_nonblock(65_536)
        rescue IO::WaitReadable
          nil
        rescue EOFError
          child.output.close
        end

        def read_records(child)
          child.buffer << child.records.read_nonblock(65_536)
          while (line = child.buffer.slice!(/\A.*\n/))
            line.start_with?("R") ? record_result(child, line) : hand_next_test(child)
          end
        rescue IO::WaitReadable
          nil
        rescue EOFError
          reap_child(child)
        end

        # The next test to a child that asked. One that died between asking and being answered
        # leaves its test for the next child; its closed pipe says so in a moment.
        def hand_next_test(child)
          child.asked_for_work = true
          klass, name = @waiting.shift
          return child.work.close unless klass

          child.work.puts "#{klass.name}\t#{name}"
          child.playing = [klass, name]
          @reporter.prerecord(klass, name)
        rescue Errno::EPIPE
          @waiting.unshift([klass, name])
        end

        # A result is the test's own, as minitest made it to be sent, with minitest's own words
        # for it beside. One that cannot be read back here holds something only the child had
        # loaded — an error class from a file this process never required — and is said as an
        # error of the test it was, in those words.
        def record_result(child, line)
          klass, name = child.playing
          child.playing = nil
          packed, words = line[1..].chomp.split(" ", 2).map { |part| part.unpack1("m0") }
          result = begin
            Marshal.load(packed) # rubocop:disable Security/MarshalLoad
          rescue ArgumentError, TypeError => e
            Processes.error_result(klass, name, "its result could not be read back here (#{e.message}). " \
                                                "The process that played it said:\n#{words}")
          end
          @reporter.record result
        end

        # A child's results pipe closes when it ends. One that ended in the middle of a test
        # costs that test, and a new child takes its place. One that ended before asking for
        # anything could not load the tests, and every child after it would do the same: the
        # tests still waiting are reported as not played, so the run still ends in a report.
        def reap_child(child)
          @children.delete(child)
          child.records.close
          drain_output(child)
          status = Process.wait2(child.pid).last
          how = Processes.how_ended(status)
          return give_up_on_waiting(child, how) unless child.asked_for_work

          if child.playing
            said = child.printed.strip.empty? ? "" : ", having printed:\n#{child.printed}"
            @reporter.record Processes.error_result(*child.playing, "the process playing this test ended " \
                                                                    "(#{how}) before the test did#{said}")
          end
          start_child unless @waiting.empty?
        end

        def give_up_on_waiting(child, how)
          first, *rest = @waiting
          @waiting = []
          return unless first

          @reporter.record Processes.error_result(*first, "not played: a test process ended (#{how}) " \
                                                          "before it played anything, having printed:\n#{child.printed}")
          rest.each do |test|
            @reporter.record Processes.error_result(*test, "not played: a test process ended before it " \
                                                           "played anything (see #{first.join('#')})")
          end
        end

        def drain_output(child)
          read_output(child) until child.output.closed?
        rescue IO::WaitReadable
          child.output.close
        end

        def stop(child)
          Process.kill(:TERM, child.pid)
          Process.wait(child.pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
      end

      # The result of a test the parent has to speak for — its process died under it, or its own
      # result could not be read: an error saying +what+ happened.
      def error_result(klass, name, what)
        test = klass.new(name)
        error = RuntimeError.new(what)
        error.set_backtrace([])
        test.failures << Minitest::UnexpectedError.new(error)
        test.time = 0.0
        Minitest::Result.from(test)
      end

      def how_ended(status)
        status.signaled? ? "killed by SIG#{Signal.signame(status.termsig)}" : "exit #{status.exitstatus}"
      end

      # --- a child ---

      # In place of minitest's run: ask the parent for a test, play it, send the result, until
      # the parent has none left. Every child is seeded with the seed the run prints. That does
      # not make a test's random numbers the ones a single process would give it, since they
      # follow from whichever tests its child played before it, but a test that seeds its own
      # are the same.
      module PlayHandedTests
        def run(args = [])
          options = process_args(args)
          self.seed = options[:seed]
          srand seed
          Processes.play_handed_tests
          true
        end
      end

      def play_handed_tests
        records = IO.new(RECORDS_FD, "w")
        records.sync = true
        work = IO.new(WORK_FD, "r")
        [records, work].each { |pipe| pipe.close_on_exec = true }
        classes = Minitest::Runnable.runnables.to_h { |klass| [klass.name, klass] }
        loop do
          records.puts "N"
          line = work.gets or break
          class_name, name = line.chomp.split("\t", 2)
          result = classes.fetch(class_name).new(name).run
          records.puts "R#{[packed(result)].pack('m0')} #{[result.to_s].pack('m0')}"
        end
      end

      # Minitest makes a result to be sent, and makes the error in it safe to send; a failure
      # that still holds something that cannot be packed is sent as its words alone, the same
      # kind of failure it was, and the result goes without any notes a test hung on it.
      def packed(result)
        Marshal.dump(result)
      rescue TypeError
        result.failures.map! { |failure| packable?(failure) ? failure : plain_failure(failure) }
        result.metadata = {}
        Marshal.dump(result)
      end

      def packable?(failure)
        Marshal.dump(failure)
        true
      rescue TypeError
        false
      end

      def plain_failure(failure)
        backtrace = failure.backtrace || []
        if failure.is_a?(Minitest::UnexpectedError)
          error = RuntimeError.new("#{failure.error.class}: #{failure.error.message}")
          error.set_backtrace(backtrace)
          return Minitest::UnexpectedError.new(error)
        end

        plain = (failure.is_a?(Minitest::Skip) ? Minitest::Skip : Minitest::Assertion).new(failure.message)
        plain.set_backtrace(backtrace)
        plain
      end
    end
  end
end

if RubyGBA::Testing::Processes.child?
  # The mark is this process's alone: a test it plays may start a run of its own, and that run
  # is a parent like any other, with no channel to the parent on the other side of this one.
  ENV.delete(RubyGBA::Testing::Processes::CHILD_SETTING)
  Minitest.singleton_class.prepend(RubyGBA::Testing::Processes::PlayHandedTests)
else
  Minitest.singleton_class.prepend(RubyGBA::Testing::Processes::PlayInChildren)
end
