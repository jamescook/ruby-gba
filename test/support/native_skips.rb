# frozen_string_literal: true

# WHAT A NATIVE RUN DID NOT PLAY, said at the end of the run: its skips counted by reason, and
# how many test classes it left to the interpreter.
#
# A file opted into native runs keeps its tests that native cannot play yet by skipping them —
# a test that checks the cartridge in the emulator, one that asks the interpreter something the
# native lowering cannot answer. Each skip is honest and says why. What a skip can do is pile up
# unseen: minitest prints one letter for each, so a run that skips forty tests looks much like one
# that skips four. Said as a count per reason on every native run, the pile is in plain sight.
#
# The classes that name the interpreter alone are quieter still: they run nothing here and print
# nothing. Every class has to say where it runs (TestSuites), so they can be counted, and the
# count is how far the native lowering is from playing the whole suite.
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
    report_skips
    report_classes(TestSuites.classes_by_lowerings(Minitest::Runnable.runnables))
  end

  private

  def report_skips
    return if @reasons.empty?

    @io.puts "\nSkipped on this native run, by reason:"
    @reasons.sort_by { |reason, count| [-count, reason] }.each { |reason, count| @io.puts format("%5d  %s", count, reason) }
  end

  def report_classes(counts)
    @io.puts "\nTest classes, by where they run:"
    @io.puts format("%5d  on both lowerings", counts.fetch(:both))
    @io.puts format("%5d  on the native lowering alone", counts.fetch(:native_only))
    @io.puts format("%5d  on the interpreter alone, so not played here (they say `runs_on :reference`)",
                    counts.fetch(:interpreter_only))
  end
end

module Minitest
  def self.plugin_native_skips_init(_options) = reporter << NativeSkips.new
end
Minitest.extensions << "native_skips"
