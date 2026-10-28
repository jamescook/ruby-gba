# frozen_string_literal: true

module VBlank
  module IR
    # HOW A RUMBLE'S PATTERN IS READ, as every backend that runs a motor reads it (`rumble`,
    # Nodes::Rumble). A pattern is eight bits, one a frame, turned a place to the right each frame:
    # the motor runs on a frame whose lowest bit, after the turn, is 1. That is how the Color's own
    # games keep one — Pokémon Pinball turns its pattern so — so a number from one of them plays
    # here as it plays there: its frames come from bit 1, then 2 and up to 7, then bit 0.
    module Rumble
      # The most frames one rumble lasts: what 16 bits hold, past eighteen minutes.
      MOST_FRAMES = 0xFFFF

      # Each of a pattern's eight frames, the first first, is this bit of it.
      FRAME_BITS = Array.new(8) { |frame| (frame + 1) % 8 }.freeze

      module_function

      # The pattern whose frames are +frames+, eight Booleans, the first first.
      def bits_of(frames) = frames.each_with_index.sum { |on, frame| on ? 1 << FRAME_BITS.fetch(frame) : 0 }

      # One frame of +bits+: whether the motor runs on it, and the pattern to read the next from.
      def step(bits)
        turned = ((bits >> 1) | (bits << 7)) & 0xFF
        [turned.odd?, turned]
      end

      # +frames+ held to what one rumble lasts: none for fewer than none.
      def frames(frames) = frames.clamp(0, MOST_FRAMES)
    end
  end
end
