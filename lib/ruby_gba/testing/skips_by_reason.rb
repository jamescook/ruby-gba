# frozen_string_literal: true

module RubyGBA
  module Testing
    # WHAT A NATIVE OR JAVASCRIPT RUN DID NOT PLAY, said at the end of the run: its skips counted
    # by reason.
    #
    # A test the native lowering cannot play skips itself there, and says why (see
    # Testing#skip_on_native). What a skip can do is pile up unseen: minitest prints one letter
    # for each, so a run that skips forty tests looks much like one that skips four. Said as a
    # count per reason on every native run, the pile is in plain sight.
    #
    # A reporter rather than anything kept by the tests, because it reads results the runner
    # already hands it and so keeps nothing the tests could share.
    class SkipsByReason < Minitest::AbstractReporter
      def initialize(io = $stdout)
        super()
        @io = io
        @reasons = Hash.new(0)
      end

      def record(result)
        @reasons[result.failure.message] += 1 if result.skipped?
      end

      def report
        return if @reasons.empty?

        @io.puts "\nSkipped on this #{Testing.lowering == :js ? "JavaScript" : "native"} run, by reason:"
        @reasons.sort_by { |reason, count| [-count, reason] }.each { |reason, count| @io.puts format("%5d  %s", count, reason) }
      end
    end
  end
end

module Minitest
  def self.plugin_skips_by_reason_init(_options) = reporter << RubyGBA::Testing::SkipsByReason.new
end
Minitest.extensions << "skips_by_reason"
