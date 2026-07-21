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

      module_function

      # Whether +name+ is a button a program can read.
      def known?(name)
        NAMES.include?(name)
      end
    end
  end
end
