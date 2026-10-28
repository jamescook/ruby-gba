# frozen_string_literal: true

module VBlank
  module Audio
    # WHICH SPEAKER A NOTE PLAYS FROM — the left, the right, or both.
    #
    # The console has two speakers (or the two sides of a pair of headphones), and it sends each of
    # its voices to the left one, the right one or both by a switch per voice and per side. Every
    # voice is sent to both at power-on, and a part that says nothing stays there. The music player
    # sets a voice's switches as each note starts, so a part can move from side to side, and the
    # game's own `beep`, `noise` and `wave` send their voice to both again. A recording is mixed
    # into one stream the console plays from both, so a part that plays one cannot pan.
    Pan = Data.define(:left, :right)

    class Pan
      LEFT = new(left: true, right: false)
      RIGHT = new(left: false, right: true)
      CENTER = new(left: true, right: true)

      SIDES = { left: LEFT, right: RIGHT, center: CENTER }.freeze

      # The side a part or a note SAID: :left, :right or :center, or nil when it said nothing.
      # +where+ names who said it, as the start of a sentence.
      def self.said(side, where:)
        return nil if side.nil?

        SIDES.fetch(side) do
          raise ArgumentError, "#{where} says `pan: #{side.inspect}`. A note plays from :left, :right, or " \
                               ":center for both speakers. To fix this, give one of those."
        end
      end

      # The side a note plays from, as the log names it: :left or :right, or nil for both.
      def self.side_of(pan)
        return nil if pan.nil? || pan == CENTER

        pan.left ? :left : :right
      end

      # A recording is mixed into the stream both speakers play. +who+ names the part, as the start
      # of a sentence.
      def self.refuse_recorded!(who)
        raise ArgumentError, "#{who} says `pan`, but it plays a recording, and every recording plays from both " \
                             "speakers. Only a square part, the wave part or the drums can pan. To fix this, " \
                             "remove `pan` from this part and from its notes."
      end

      # The two bits a note keeps its side in: 1 for the left alone, 2 for the right alone, and
      # nought for both, so a note that says nothing is a note that plays from both.
      LEFT_BITS = 1
      RIGHT_BITS = 2

      BITS = { left: LEFT_BITS, right: RIGHT_BITS }.freeze

      # The bits a note keeps +side+ in (:left, :right, or nil for both), and the side back from them.
      def self.bits_of(side) = BITS.fetch(side, 0)
      def self.side_from_bits(bits) = BITS.key(bits)
    end
  end
end
