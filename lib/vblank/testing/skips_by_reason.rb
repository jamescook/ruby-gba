# frozen_string_literal: true

module VBlank
  module Testing
    # WHAT A RUN DID NOT PLAY, said at the end of the run: its skips counted by reason.
    #
    # A skip means one thing in a run: the run's lowering lacks a feature the test plays
    # (MissingFeature), which the checked player says itself or a test says with skip_on_native and
    # its siblings. What a skip can do is pile up unseen: minitest prints one letter for each, so a
    # run that skips forty tests looks much like one that skips four. Said as a count per reason
    # on every run, the pile is in plain sight.
    #
    # ANY OTHER SKIP FAILS THE RUN, named. A test that skips for a reason that is not a missing
    # feature is a test in the wrong place — one only another run has anything to check in — and
    # the place for it is a folder or a block only that run defines (see "Every test plays on
    # every lowering" in .claude/rules/testing.md). Left as a skip, it is an S on every run that
    # checks nothing there.
    #
    # A reporter rather than anything kept by the tests, because it reads results the runner
    # already hands it and so keeps nothing the tests could share.
    class SkipsByReason < Minitest::AbstractReporter
      def initialize(io = $stdout)
        super()
        @io = io
        @reasons = Hash.new(0)
        @strays = []
      end

      def record(result)
        return unless result.skipped?

        @reasons[result.failure.message] += 1
        @strays << "#{result.klass}##{result.name}: #{result.failure.message}" unless MissingFeature === result.failure
      end

      def passed? = @strays.empty?

      def report
        unless @reasons.empty?
          @io.puts "\nSkipped on this #{Testing::RUN.title} run, by reason:"
          @reasons.sort_by { |reason, count| [-count, reason] }.each { |reason, count| @io.puts format("%5d  %s", count, reason) }
        end
        return if @strays.empty?

        @io.puts "\nSkipped for a reason that is not a missing feature, which fails the run. Each such test " \
                 "belongs in a folder or a block only the run it is about defines:"
        @strays.sort.each { |stray| @io.puts "  #{stray}" }
      end
    end
  end
end

module Minitest
  def self.plugin_skips_by_reason_init(_options) = reporter << VBlank::Testing::SkipsByReason.new
end
Minitest.extensions << "skips_by_reason"
