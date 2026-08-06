# frozen_string_literal: true

module RubyGBA
  module IR
    # The IR's reference integer semantics: **signed 32-bit two's-complement
    # with wraparound**. This is a cross-backend contract, not a hardware detail,
    # so it lives in the IR core and every backend must honor it.
    #
    # Why pin it, and why here:
    #
    # On the console an IR variable is a 32-bit register — add/sub/mul wrap at
    # 2**32 and comparisons are signed. Nobody writing game code thinks about it;
    # the silicon just does it. But the IR is meant to lower to *other* backends
    # too (a JavaScript interpreter, say), where a number is a float64. The moment
    # a value wraps, a multiply overflows, or a signed compare straddles the sign
    # boundary, an unguarded backend would silently disagree with the register
    # one — a divergence invisible until a game misbehaves in one backend and not
    # the other. Cheap to prevent now, miserable to retrofit later.
    #
    # So IR arithmetic is *defined* as whatever this module computes. The value
    # model builds on it and any interpreter calls it; none of them get to
    # reinvent (and subtly disagree about) integer math.
    module Int32
      # Low 32 bits, and the signed range of a 32-bit two's-complement integer.
      MASK = 0xFFFF_FFFF
      MIN  = -(2**31)      # -2_147_483_648
      MAX  = (2**31) - 1   #  2_147_483_647

      module_function

      # Normalize any Ruby integer to a signed 32-bit value: keep the low 32
      # bits, then read the top bit as the sign (so 0x8000_0000 is MIN, not a big
      # positive). Every operation below routes through this, so "what wrapping
      # means" is defined in exactly one place.
      def wrap(n)
        n &= MASK
        n >= 0x8000_0000 ? n - 0x1_0000_0000 : n
      end

      def add(a, b)
        wrap(wrap(a) + wrap(b))
      end

      def sub(a, b)
        wrap(wrap(a) - wrap(b))
      end

      def mul(a, b)
        wrap(wrap(a) * wrap(b))
      end

      # Multiply two numbers that each carry +bits+ fraction bits, and give back a
      # number carrying the same +bits+ — the operation `mul` cannot do.
      #
      # A whole number can't hold a fraction, so a program that needs one stores the
      # value multiplied up by a fixed amount: with 16 fraction bits, 1.5 is kept as
      # 1.5 * 65536. Adding two of those works unchanged. MULTIPLYING two of them
      # does not: the answer comes out multiplied up TWICE, so it has to be divided
      # back down once. That would be fine, except the doubled-up product needs more
      # than 32 bits to exist before it can be divided down — 1.5 * 1.5 in 16 fraction
      # bits multiplies 98304 by 98304, which is 9,663,676,416, twice over the wrap
      # point. Plain `mul` wraps there and returns nonsense.
      #
      # So the product is formed at full width FIRST and only then brought back down.
      # The final result is still a 32-bit value and still wraps if it doesn't fit —
      # what changes is that the intermediate no longer has to.
      def mul_fix(a, b, bits)
        wrap((wrap(a) * wrap(b)) >> bits) # Ruby's >> on a negative floors, as ASR does
      end

      # Divide by 2**bits, rounding DOWN — toward minus infinity, not toward zero.
      #
      # That last part is the whole reason this is not just `div(a, 2**bits)`. Ordinary
      # division here truncates toward zero, so -1 / 2 is 0. Rounding down gives -1. For
      # a number carrying a fraction the rounding-down answer is the one that stays
      # consistent: it is exactly what dropping the low +bits+ of the number does, so a
      # value converted to a whole number and a value multiplied by another both round
      # the same way, and the two agree at the boundary.
      #
      # A machine spells this as a shift, which is why the name says shift. The meaning
      # is the division above.
      def shift_right(a, bits)
        wrap(wrap(a) >> bits) # Ruby's >> on a negative rounds down, which is the point
      end

      def neg(a)
        wrap(-wrap(a))
      end

      # Signed division truncated toward zero — like the console's BIOS Div (and
      # C), not Ruby's `/`. Ruby's `/` FLOORS: it steps to the whole number to the
      # LEFT on the number line, so -7 / 2 is -4, not the -3 we want. That only
      # bites on negatives. Dividing the magnitudes (both positive, where "left"
      # and "toward zero" are the same step) then reapplying the sign avoids it:
      # 7 / 2 = 3, negate -> -3.
      def div(a, b)
        a = wrap(a)
        b = wrap(b)
        quotient = a.abs / b.abs
        quotient = -quotient if a.negative? != b.negative?
        wrap(quotient)
      end

      # Signed ordering: -1 / 0 / 1, comparing both operands as signed 32-bit
      # values — which is why 0xFFFF_FFFF (i.e. -1) is *less* than 1 here, not
      # greater as the raw bit pattern would suggest.
      def cmp(a, b)
        wrap(a) <=> wrap(b)
      end
    end
  end
end
