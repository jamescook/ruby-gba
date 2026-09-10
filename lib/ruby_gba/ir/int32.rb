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

      # How many bits a whole number has here — and so how far a shift can go before
      # there is nothing left to move.
      BITS = 32

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

      # The other half of holding a fraction: dividing one of those numbers by another.
      #
      # Two numbers multiplied up by the same amount divide that amount straight back
      # out — 3.0 over 1.5 is 196608 over 98304, which is 2, and the answer has lost the
      # multiplying-up that made it a fraction. So the numerator has to be multiplied up
      # AGAIN first, and that is the mirror of the problem #mul_fix has: 3.0 with 16
      # fraction bits is 196608, and multiplying it up once more needs 48 bits before
      # anything is divided.
      #
      # So the numerator is widened FIRST and only then divided. +bits+ is how far it is
      # widened, which is what decides the answer's own scale. It truncates toward zero,
      # like every other `/` here.
      #
      # An answer too big to hold is HELD AT THE END OF THE RANGE rather than wrapped,
      # which is the one place this differs from #mul_fix. Dividing by a very small
      # fraction genuinely has no room for its answer — a wall one hundredth of a step
      # away is a wall thousands of pixels high — and of the two wrong answers available,
      # "as tall as a number goes" is the one that still looks like a wall. Wrapping
      # would make it negative, which looks like nothing at all.
      def div_fix(a, b, bits)
        numerator = wrap(a) << bits # widened, so #div's own wrapping cannot be used here
        divisor = wrap(b)
        quotient = numerator.abs / divisor.abs
        quotient = -quotient if numerator.negative? != divisor.negative?
        quotient.clamp(MIN, MAX)
      end

      # --- reading and writing the bits themselves ---
      #
      # A whole number here is 32 bits of two's complement, and these four work on
      # those bits directly rather than on the number they spell. Each is Ruby's own
      # answer brought back into range: Ruby already does bitwise arithmetic in two's
      # complement and already sign-extends a negative forever, so -1 & 0xFF is 255 on
      # both sides of the line and ~5 is -6 on both.

      def bit_and(a, b)
        wrap(wrap(a) & wrap(b))
      end

      def bit_or(a, b)
        wrap(wrap(a) | wrap(b))
      end

      def bit_xor(a, b)
        wrap(wrap(a) ^ wrap(b))
      end

      def bit_not(a)
        wrap(~wrap(a))
      end

      # A SHIFT COUNT OUTSIDE 0...32 EMPTIES THE NUMBER, and that is a decision rather
      # than something that fell out. Moving every bit of a 32-bit number 32 places
      # puts all of them off the end, so what is left is nothing: zero going left, and
      # going right whatever was filling in behind — 0 for a number that was positive
      # and -1 for one that was negative.
      #
      # A NEGATIVE count does the same, rather than turning round and shifting the
      # other way. Ruby does turn round (8 >> -2 is 32), and this is the one place the
      # framework declines to follow it: a negative shift count in a game is a mistake,
      # and quietly reversing direction hides the mistake instead of showing it. Going
      # off the end is at least the answer the count asked for.
      #
      # Both backends pin this, so a count the game works out gives the same answer
      # wherever the program runs.
      def shift_left(a, count)
        return 0 unless shifts_within_the_number?(count)

        wrap(wrap(a) << count)
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
      # A machine spells this as a shift, which is why the name says shift. It is also
      # the same operation the program's own `>>` asks for — moving the bits down, with
      # the sign filling in behind — so both arrive here, and an out-of-range count
      # empties the number as described above.
      def shift_right(a, bits)
        return wrap(a).negative? ? -1 : 0 unless shifts_within_the_number?(bits)

        wrap(wrap(a) >> bits) # Ruby's >> on a negative rounds down, which is the point
      end

      # Does this count move bits about inside the number, rather than pushing all of
      # them off one end?
      def shifts_within_the_number?(count)
        count >= 0 && count < BITS
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

      # What is left over after division — with RUBY's meaning, not the one that falls
      # out of #div.
      #
      # Those differ, and the difference is the whole point of having this. #div
      # truncates toward zero to match the console's BIOS, so the leftover it implies
      # takes the sign of the NUMERATOR: -1 would leave -1. Ruby's `%` takes the sign of
      # the divisor, so -1 % 64 is 63. That is what wrapping wants — an angle one step
      # below zero is one step below a full turn, and a map coordinate off the left edge
      # is against the right one. A wrap that returned -1 would index off the front of
      # every table it was used on.
      #
      # Ruby's meaning wins here because the audience knows Ruby. It does mean `/` and
      # `%` do not decompose consistently on negatives, which is a deliberate and
      # documented wrinkle rather than an oversight.
      def mod(a, b)
        a = wrap(a)
        b = wrap(b)
        raise ZeroDivisionError, "cannot take what is left over after dividing by zero" if b.zero?

        wrap(a.modulo(b))
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
