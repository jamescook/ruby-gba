# frozen_string_literal: true

module RubyGBA
  module IR
    # The button vocabulary: the set of button names a program may read with
    # `held` / `pressed`. This is a cross-backend contract, not a backend detail,
    # so it lives in the IR core next to Int32 — every backend agrees on the SAME
    # names, then maps each to its own world (a hardware key bit on the console, a
    # set membership in the interpreter, a key event in a browser). The vocabulary
    # is shared; the mapping is per-backend.
    #
    # This mirrors how color works: the IR carries the name (:a, :red) and each
    # backend resolves it. Naming a button that isn't here is almost always a typo,
    # and one that would otherwise read as "never pressed" — so callers check
    # against this list and say so plainly.
    module Buttons
      # The ten Game Boy Advance buttons, by the names a program uses.
      NAMES = %i[a b select start right left up down r l].freeze

      # ANY BUTTON AT ALL, which is not a button and so is not in NAMES: `held(:any)` holds
      # while one of them is down, and `pressed(:any)` on a frame one of them went down —
      # including while another is still held, the same edge each button has on its own. It
      # is how a game leaves an attract screen.
      ANY = :any

      module_function

      # Whether +name+ is a button a program can read.
      def known?(name)
        NAMES.include?(name)
      end

      # Whether `held` and `pressed` can ask about +name+: a button, or any of them.
      def readable?(name) = known?(name) || name == ANY
    end
  end
end
