# frozen_string_literal: true

module RubyGBA
  module Calibration
    # The arithmetic that turns emulator readings into a weight. Plain numbers in, plain
    # numbers out, no emulator and no ROMs — so it can be tested with known inputs.
    #
    # Nearly every weight in the model is one of these three shapes:
    #
    #   MARGINAL   two ROMs that differ only in how many of the thing they do, over the
    #              difference. That cancels the fixed per-frame overhead — the game loop,
    #              the vblank wait, the repeat counter — and leaves the thing's own cost.
    #              This is the workhorse.
    #   RESIDUAL   the whole cost of something, minus the parts already priced. Used where
    #              a compound op has a fixed part hiding under its per-row and per-pixel
    #              parts (a blit's start-up, a digit's glyph lookup).
    #   FIT        two points on a line, for a cost of the form base + slope * n (the
    #              software mixer: a floor it pays whatever happens, plus a rate per voice).
    #
    # A weight is only ever as good as the range it was measured over, which is why each of
    # these hands back the range it saw as well as the number — see {Domain}.
    module Reductions
      # A marginal rate: what one more of something costs, with everything both ROMs share
      # cancelled. +over+ is how many MORE of the thing the high reading did.
      def self.marginal(high, low, over:)
        raise ArgumentError, "a marginal rate needs a non-zero spread to divide by" if over.to_f.zero?

        (high - low) / over.to_f
      end

      # What is left of a total once the parts already priced are taken out. Negative is
      # possible and is a real signal — it means the parts over-account for the whole, so
      # one of them is measuring something this total does not contain.
      def self.residual(total, *parts)
        total - parts.sum
      end

      # base + slope * n through two points. Answers [slope, base]: the cost of one more,
      # and what it costs with none at all.
      def self.fit(low_n, low_cost, high_n, high_cost)
        raise ArgumentError, "a fit needs two different counts" if low_n == high_n

        slope = (high_cost - low_cost) / (high_n - low_n).to_f
        [slope, low_cost - (slope * low_n)]
      end

      # How many times faster one reading is than another. Used for the one weight that is
      # a factor rather than a cost.
      def self.ratio(slower, faster)
        raise ArgumentError, "cannot take a ratio against zero" if faster.to_f.zero?

        slower / faster.to_f
      end
    end
  end
end
