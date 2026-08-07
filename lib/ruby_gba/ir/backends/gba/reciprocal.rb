# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # How to divide by a fixed number without dividing.
        #
        # The chip has no divide instruction at all. A division traps into a routine in
        # the console's BIOS that works the answer out a bit at a time, and that costs
        # roughly what a hundred ordinary instructions cost. But the chip CAN multiply
        # two 32-bit numbers and keep the whole 64-bit product (SMULL), and dividing by
        # a fixed number is the same as multiplying by one over it.
        #
        # One over ten has no exact binary form, so we use a whole number close to
        # 2**k / 10 instead and then throw the low k bits of the product away — the same
        # sum, scaled up and then back down. The catch is that "close to" has to be close
        # ENOUGH: the rounded reciprocal must give the exactly right answer for every one
        # of the four billion numerators, not merely for most of them. Rounding up by a
        # hair is safe as long as the hair can never push a numerator over the next whole
        # number, and how big a power of two you need before that is true depends on the
        # divisor.
        #
        # The search below settles it. It is Granlund and Montgomery's method, in the
        # form Hacker's Delight gives: walk k upward and stop at the first k where the
        # error still cannot reach the nearest boundary. The result is a multiplier and a
        # shift that are exact for the whole 32-bit range, worked out here at build time
        # so the console only ever does the multiply.
        #
        # Where these divisions come from is worth knowing, because most of them are not
        # the game's own arithmetic. A number on screen is the big one: showing a score,
        # a timer or an ammo count means pulling a number apart into digits, and a digit
        # is a divide by ten. A six-digit score works out sixteen of them every frame,
        # and the person writing the game wrote `draw_number :score` — not one of those
        # divides is theirs to avoid, however well they know this machine. The rest is
        # ordinary game arithmetic that happens not to land on a power of two: seconds
        # from frames is a divide by 60, a percentage is a divide by 100, sharing
        # something out evenly is a divide by however many there are.
        module Reciprocal
          WORD = 1 << 32
          SIGN = 1 << 31

          # What the console has to do to divide by one particular number: multiply by
          # +multiplier+, keep the high half of the product, shift it down by +shift+,
          # and — when +add_numerator+ — add the numerator back in on the way.
          #
          # That last one looks odd and is bookkeeping. For some divisors the multiplier
          # the search finds does not fit in a signed 32-bit register: it wants to be a
          # little over two billion, and a register that size counts to just under.
          # Storing it anyway makes it read as a negative number, exactly two billion odd
          # too small, and adding the numerator back puts that difference right.
          Recipe = Data.define(:multiplier, :shift, :add_numerator)

          class << self
            # The recipe for dividing by +divisor+, which must be 2 or more. (A negative
            # divisor is handled by dividing by its size and negating the answer, and 1,
            # 0 and -1 have no reciprocal worth finding.)
            def for(divisor)
              raise ArgumentError, "reciprocal needs a divisor of 2 or more" if divisor < 2

              multiplier, power = search(divisor)
              Recipe.new(multiplier: multiplier, shift: power - 32,
                         add_numerator: multiplier >= SIGN)
            end

            private

            # Find the smallest 2**power whose rounded-up reciprocal of +divisor+ is exact
            # for every 32-bit numerator, and return [that reciprocal, power].
            #
            # Two running divisions drive it, both done by hand so they stay exact: 2**p
            # over the divisor (the reciprocal being built), and 2**p over the hardest
            # numerator to get right — the one furthest out in the range that sits
            # closest to a boundary, so if the rounding error clears that one it clears
            # every one. Doubling p is one step of long division on each — double the
            # quotient and the remainder, and carry when the remainder has grown past the
            # divisor — so the whole search is adds and compares on whole numbers.
            def search(divisor)
              nearest = SIGN - 1 - SIGN % divisor
              power = 31
              tight_q, tight_r = SIGN.divmod(nearest)
              recip_q, recip_r = SIGN.divmod(divisor)

              loop do
                power += 1
                tight_q, tight_r = double(tight_q, tight_r, nearest)
                recip_q, recip_r = double(recip_q, recip_r, divisor)
                slack = divisor - recip_r
                break if tight_q > slack || (tight_q == slack && tight_r.positive?)
              end

              [(recip_q + 1) & (WORD - 1), power]
            end

            # One step of long division: double a quotient and its remainder, carrying
            # when the remainder has reached the divisor.
            def double(quotient, remainder, divisor)
              quotient *= 2
              remainder *= 2
              return [quotient + 1, remainder - divisor] if remainder >= divisor

              [quotient, remainder]
            end
          end
        end
      end
    end
  end
end
