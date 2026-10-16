# frozen_string_literal: true

# WHAT A NATIVE RUN DID NOT PLAY, said at the end of the run: its skips counted by reason.
#
# A test the native lowering cannot play skips itself there — a test that checks the cartridge in
# the emulator, one that asks the interpreter something the native lowering cannot answer yet.
# Each skip is honest and says why. What a skip can do is pile up unseen: minitest prints one
# letter for each, so a run that skips forty tests looks much like one that skips four. Said as a
# count per reason on every native run, the pile is in plain sight.
#
# A reporter rather than anything kept by the tests, because it reads results the runner already
# hands it and so keeps nothing the tests could share.
class NativeSkips < Minitest::AbstractReporter
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

    @io.puts "\nSkipped on this native run, by reason:"
    @reasons.sort_by { |reason, count| [-count, reason] }.each { |reason, count| @io.puts format("%5d  %s", count, reason) }
  end
end

module Minitest
  def self.plugin_native_skips_init(_options) = reporter << NativeSkips.new
end
Minitest.extensions << "native_skips"
