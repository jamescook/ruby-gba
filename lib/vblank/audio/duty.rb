# frozen_string_literal: true

module VBlank
  module Audio
    # A SQUARE NOTE'S TONE SHAPE — its duty, how much of each wave the voice holds high — or a shape
    # that changes while the note holds.
    #
    # A square voice's wave is high for part of each wave and low for the rest: an eighth of it is
    # thin and reedy, half is the hollow square of a clarinet. The voice takes a new shape at once,
    # without starting its note again, so the music player can change it a frame at a time: a note
    # given a list of shapes plays the first on its first frame, the next on its next, and round
    # again until the part's next note — the shimmer the console's own music engines make by
    # rotating four shapes a frame. Two shapes take turns; four go round.
    #
    # Kept as four shapes always, a frame each, so two are the same pair twice.
    Duty = Data.define(:shapes)

    class Duty
      # Each shape's number, two bits, thinnest first. They are the numbers the consoles' square
      # voices take a shape by, so a lowering writes them straight into its voice. :square is :half
      # by another name.
      NUMBERS = { eighth: 0, quarter: 1, half: 2, three_quarter: 3 }.freeze
      NAMES = NUMBERS.invert.freeze
      SHAPE_NAMES = [*NUMBERS.keys, :square].freeze
      FRAMES = 4

      # Does the shape change while the note holds?
      def steps? = shapes.uniq.length > 1

      # The shape on the note's frame number +frame+ (from 0).
      def at(frame) = shapes[frame % FRAMES]

      # One shape, every frame.
      def self.one(shape) = new(shapes: ([named(shape)] * FRAMES).freeze)

      # THE SHAPE A NOTE SAID: a shape's name (:eighth, :quarter, :half, :three_quarter), or a list
      # of two or four of them to step through, or nil when it said nothing. +where+ names who said
      # it, as the start of a sentence.
      def self.said(value, where:)
        return nil if value.nil?
        return one(checked_name(value, value, where)) unless value.is_a?(Array)

        refuse_unknown!(value, where) unless [2, FRAMES].include?(value.length)
        names = value.map { |shape| named(checked_name(shape, value, where)) }
        new(shapes: (names * (FRAMES / names.length)).freeze)
      end

      # WHAT A PART SAID OF ITS DUTY, as a part keeps it: its one shape, and its shapes when it gave a
      # list to step through (nil when it gave one shape, which is what a part always did).
      def self.of_part(value, where:)
        return [value, nil] unless value.is_a?(Array)

        stepping = said(value, where: where)
        [stepping.at(0), stepping]
      end

      def self.named(shape) = shape == :square ? :half : shape

      def self.checked_name(shape, value, where)
        SHAPE_NAMES.include?(shape) ? shape : refuse_unknown!(value, where)
      end
      private_class_method :checked_name

      def self.refuse_unknown!(value, where)
        raise ArgumentError, "#{where} says `duty: #{value.inspect}`. A duty is :eighth, :quarter, :half or " \
                             ":three_quarter. A note can also step through a list of two or four duties, a frame " \
                             "each. To fix this, give a duty or a list of two or four."
      end
      private_class_method :refuse_unknown!

      # Only a square voice has a shape to change. +who+ names the part, as the start of a sentence;
      # +by_part+ says the part gave the list, and not a note.
      def self.refuse_off_square!(who, by_part:)
        if by_part
          raise ArgumentError, "#{who} says a list of duties, but the part does not play the square wave. Only a " \
                               "square part has a duty. To fix this, remove the list from `duty`."
        end

        raise ArgumentError, "#{who} gives a note a duty, but the part does not play the square wave. Only a " \
                             "square part has a duty. To fix this, remove `duty:` from the notes of this part."
      end

      # The eight bits a note keeps it in: each frame's shape's number (NUMBERS), the first frame's
      # lowest.
      def bits = shapes.each_with_index.sum { |shape, frame| NUMBERS.fetch(shape) << (2 * frame) }

      def self.from_bits(bits) = new(shapes: Array.new(FRAMES) { |frame| NAMES.fetch((bits >> (2 * frame)) & 3) }.freeze)
    end
  end
end
