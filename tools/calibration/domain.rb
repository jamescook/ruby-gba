# frozen_string_literal: true

module RubyGBA
  module Calibration
    # Where a weight was measured, and so where it can be trusted.
    #
    # WHY A WEIGHT NEEDS THIS. Almost every weight in the model is a MARGINAL rate: two ROMs
    # that differ only in how many of the thing they do, differenced over the difference.
    # That is the right way to measure one more of something, and it has one property worth
    # understanding — it cancels everything the two ROMs share, INCLUDING anything the thing
    # itself pays only once.
    #
    # So a marginal rate measured between 300 and 900 passes of a loop describes a loop of
    # 300 to 900 passes. A four-pass loop pays its setup over four passes instead of
    # hundreds, and the rate says nothing about that. Measured, that is an eighth of the
    # cost missing — and nothing in the model knew to mention it, because a weight was a
    # bare number in a hash with no memory of how it came to be.
    #
    # A domain is that memory: what was varied to measure this weight, and between which
    # two counts. It is emitted by the calibration itself rather than written by hand, so it
    # cannot drift away from the measurement it describes.
    #
    # +varies+ names the quantity, as a program-visible thing where there is one — :passes
    # for a loop's trip count, :sprites for how many are on screen, :overlap_pixels for how
    # big a collision test's overlap is. nil means the weight has no countable regime: an
    # add costs what an add costs, and there is no number in a program that changes it. Only
    # a named quantity can be checked against a program, so nil means "recorded, never
    # warned about".
    Domain = Data.define(:varies, :from, :to, :note) do
      def initialize(varies: nil, from: nil, to: nil, note: nil)
        super
      end

      # Is +count+ of the varied thing inside where this weight was measured?
      def covers?(count)
        return true if varies.nil? || from.nil? || to.nil?

        count >= from && count <= to
      end

      # Below the floor is the direction that hurts. A marginal rate excludes whatever the
      # thing pays once, and the smaller the count the larger a share of the cost that is —
      # so extrapolating DOWN under-charges, while extrapolating up is usually harmless.
      def under?(count)
        !varies.nil? && !from.nil? && count < from
      end

      def range_text
        return note.to_s if varies.nil?

        "#{varies} #{from}..#{to}"
      end

      # The Ruby source for this domain, for the generated fixture.
      def to_source
        parts = []
        parts << "varies: #{varies.inspect}" if varies
        parts << "from: #{from.inspect}" if from
        parts << "to: #{to.inspect}" if to
        parts << "note: #{note.inspect}" if note
        "{ #{parts.join(', ')} }"
      end
    end
  end
end
