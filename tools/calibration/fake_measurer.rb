# frozen_string_literal: true

module RubyGBA
  module Calibration
    # A {Measurer} that answers from a table instead of the emulator, so the calibration's
    # recipes and arithmetic can be tested without one.
    #
    # It is keyed by the NAME each benchmark passes, which is already unique — that is what
    # makes the seam this narrow. An unknown name RAISES rather than answering zero: a test
    # that quietly measured nothing would pass while proving nothing, and the point of a
    # canned reading is knowing exactly which reading fed which weight.
    class FakeMeasurer
      attr_reader :asked # every [kind, name] this was asked for, in order

      def initialize(busy: {}, stall: {}, total: {}, default: nil)
        @readings = { busy: busy, stall: stall, total: total }
        @default = default
        @asked = []
      end

      def busy(name, _rom) = reading(:busy, name)
      def stall(name, _rom) = reading(:stall, name)
      def total(name, _rom) = reading(:total, name)

      private

      def reading(kind, name)
        @asked << [kind, name]
        table = @readings.fetch(kind)
        return table.fetch(name) if table.key?(name)
        return @default unless @default.nil?

        raise KeyError, "no canned #{kind} reading for #{name.inspect} " \
                        "(known: #{table.keys.sort.join(', ')})"
      end
    end
  end
end
