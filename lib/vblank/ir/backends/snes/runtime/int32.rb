# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE ARITHMETIC OF IR::Int32 that is too long to write where it is used: multiplying,
          # dividing, the remainder, shifting by a count worked out as the game runs, and the two
          # sums on numbers with a fraction. Adding, subtracting, the bitwise sums, turning a number
          # round and comparing are a handful of instructions each, and the lowering writes them
          # where they are used (Lowering).
          #
          # A 32-bit number is two 16-bit halves, the low one first, as the console keeps a number
          # anywhere in memory. With A 16 bits wide, a sum of two numbers is a sum of the low halves
          # and then of the high halves with the carry from the first — the 65816 adds with the
          # carry it was left with (ADC), so the carry flag is cleared before the first.
          #
          # The console has a multiplier and a divider of its own, but they take 8 bits by 8 and 16
          # by 8, so a 32-bit product would be many of them added up. These routines do it the way
          # it is done on paper: one bit of the multiplier (or of the quotient) at a time, at most
          # 32 times (64 for a fraction), shifting and adding.
          #
          # Every routine takes its numbers in R0, R1 and R2 (Memory.register) and leaves its answer
          # in R0. They are reached with JSL and return with RTL, with A, X and Y 16 bits wide on
          # the way in and the way out.
          module Int32
            R0 = Memory.register(0)
            R1 = Memory.register(1)
            R2 = Memory.register(2)

            # Where the routines keep what they are working on, on the direct page: a product or a
            # numerator of up to 64 bits, what is added to it, the remainder, and the signs.
            Scratch = Data.define(:wide, :addend, :rest, :signs)

            module_function

            def scratch(memory)
              Scratch.new(wide: memory.scratch(8), addend: memory.scratch(8), rest: memory.scratch(4),
                          signs: memory.scratch(2))
            end

            def emit(asm, scratch)
              emit_mul(asm, scratch)
              emit_unsigned_divide(asm, scratch)
              emit_div(asm, scratch)
              emit_mod(asm, scratch)
              emit_shifts(asm)
              emit_mul_fix(asm, scratch)
              emit_div_fix(asm, scratch)
              emit_helpers(asm)
              emit_make_positive(asm, scratch)
            end

            # rt_mul32: R0 × R1, the low 32 bits — which are the same whether the two are read as
            # signed or not, so no signs are looked at. R0 is shifted left a place for every bit of R1,
            # and added to the product where that bit is one.
            def emit_mul(asm, s)
              p = s.wide
              asm.label("rt_mul32")
              asm.stz(asm.dp(p))
              asm.stz(asm.dp(p + 2))
              asm.label("rt_mul32_bit")
              asm.lda(asm.dp(R1))
              asm.ora(asm.dp(R1 + 2))
              asm.beq("rt_mul32_done")
              asm.lsr(asm.dp(R1 + 2))
              asm.ror(asm.dp(R1))
              asm.bcc("rt_mul32_shift")
              asm.clc
              asm.lda(asm.dp(p))
              asm.adc(asm.dp(R0))
              asm.sta(asm.dp(p))
              asm.lda(asm.dp(p + 2))
              asm.adc(asm.dp(R0 + 2))
              asm.sta(asm.dp(p + 2))
              asm.label("rt_mul32_shift")
              asm.asl(asm.dp(R0))
              asm.rol(asm.dp(R0 + 2))
              asm.bra("rt_mul32_bit")
              asm.label("rt_mul32_done")
              asm.lda(asm.dp(p))
              asm.sta(asm.dp(R0))
              asm.lda(asm.dp(p + 2))
              asm.sta(asm.dp(R0 + 2))
              asm.rtl
            end

            # rt_udiv32 (reached with JSR from the routines below, in the same bank): R0 ÷ R1 as
            # numbers that cannot be negative, the quotient left in R0 and the remainder in the
            # scratch's rest. Long division, a bit at a time: the numerator is shifted into the
            # remainder from the top, and wherever the divisor goes into it, it is taken away and a
            # one goes into the quotient, which fills R0 from the bottom as the numerator leaves it.
            def emit_unsigned_divide(asm, s)
              rest = s.rest
              asm.label("rt_udiv32")
              asm.stz(asm.dp(rest))
              asm.stz(asm.dp(rest + 2))
              asm.ldx(32)
              asm.label("rt_udiv32_bit")
              asm.asl(asm.dp(R0))
              asm.rol(asm.dp(R0 + 2))
              asm.rol(asm.dp(rest))
              asm.rol(asm.dp(rest + 2))
              asm.sec
              asm.lda(asm.dp(rest))
              asm.sbc(asm.dp(R1))
              asm.tay
              asm.lda(asm.dp(rest + 2))
              asm.sbc(asm.dp(R1 + 2))
              asm.bcc("rt_udiv32_no")
              asm.sta(asm.dp(rest + 2))
              asm.sty(asm.dp(rest))
              asm.inc(asm.dp(R0))
              asm.label("rt_udiv32_no")
              asm.dex
              asm.bne("rt_udiv32_bit")
              asm.rts
            end

            # rt_div32: R0 ÷ R1, rounded towards nought (Int32.div). By nought it is 1, or -1 for a
            # negative numerator. The two are made positive and divided, and the quotient turned
            # round when one of them was negative. The lowest number divided by -1 comes out as itself,
            # as Int32 has it: its size, 2^31, is the lowest number again.
            def emit_div(asm, s)
              asm.label("rt_div32")
              asm.lda(asm.dp(R1))
              asm.ora(asm.dp(R1 + 2))
              asm.bne("rt_div32_divide")
              asm.jmp(asm.abs("rt_one_signed_like_r0"))
              asm.label("rt_div32_divide")
              asm.jsr(asm.abs("rt_make_positive"))
              asm.jsr(asm.abs("rt_udiv32"))
              asm.lda(asm.dp(s.signs))
              asm.eor(asm.dp(s.signs + 1)) # the two signs' top bits, compared in one byte... see below
              asm.and_a(0x0080)
              asm.beq("rt_div32_done")
              asm.jsr(asm.abs("rt_negate_r0"))
              asm.label("rt_div32_done")
              asm.rtl
            end

            # rt_mod32: R0 modulo R1, with Ruby's meaning (Int32.mod): the answer takes the sign of
            # the divisor. By nought it is R0 itself. The remainder of the two made positive, given
            # the numerator's sign, and then the divisor added to it when it is not nought and its
            # sign is not the divisor's.
            def emit_mod(asm, s)
              rest = s.rest
              asm.label("rt_mod32")
              asm.lda(asm.dp(R1))
              asm.ora(asm.dp(R1 + 2))
              asm.bne("rt_mod32_divide")
              asm.rtl
              asm.label("rt_mod32_divide")
              # The divisor as it was, for adding at the end.
              asm.lda(asm.dp(R1))
              asm.sta(asm.dp(R2))
              asm.lda(asm.dp(R1 + 2))
              asm.sta(asm.dp(R2 + 2))
              asm.jsr(asm.abs("rt_make_positive"))
              asm.jsr(asm.abs("rt_udiv32"))
              asm.lda(asm.dp(rest))
              asm.sta(asm.dp(R0))
              asm.lda(asm.dp(rest + 2))
              asm.sta(asm.dp(R0 + 2))
              asm.lda(asm.dp(s.signs))
              asm.and_a(0x0080) # the numerator's sign
              asm.beq("rt_mod32_signed")
              asm.jsr(asm.abs("rt_negate_r0"))
              asm.label("rt_mod32_signed")
              asm.lda(asm.dp(R0))
              asm.ora(asm.dp(R0 + 2))
              asm.beq("rt_mod32_done")
              asm.lda(asm.dp(R0 + 2))
              asm.eor(asm.dp(R2 + 2))
              asm.bpl("rt_mod32_done")
              asm.clc
              asm.lda(asm.dp(R0))
              asm.adc(asm.dp(R2))
              asm.sta(asm.dp(R0))
              asm.lda(asm.dp(R0 + 2))
              asm.adc(asm.dp(R2 + 2))
              asm.sta(asm.dp(R0 + 2))
              asm.label("rt_mod32_done")
              asm.rtl
            end

            # rt_shl32 and rt_shr32: R0 shifted by R1 places. A count of 32 or more, or below
            # nought, empties the number (Int32.shift_left), or for a shift right leaves only its
            # sign (Int32.shift_right, which rounds down as the arithmetic shift does). A count of
            # 16 or more moves a half at once first.
            def emit_shifts(asm)
              { "rt_shl32" => :left, "rt_shr32" => :right }.each do |name, way|
                asm.label(name)
                asm.lda(asm.dp(R1 + 2))
                asm.bne("#{name}_out")
                asm.lda(asm.dp(R1))
                asm.cmp(32)
                asm.bcs("#{name}_out")
                asm.cmp(16)
                asm.bcc("#{name}_bits")
                asm.sbc(16) # the carry is set: exactly 16 off
                asm.sta(asm.dp(R1))
                if way == :left
                  asm.lda(asm.dp(R0))
                  asm.sta(asm.dp(R0 + 2))
                  asm.stz(asm.dp(R0))
                else
                  asm.lda(asm.dp(R0 + 2))
                  asm.sta(asm.dp(R0))
                  asm.jsr(asm.abs("rt_sign_half"))
                  asm.sta(asm.dp(R0 + 2))
                end
                asm.label("#{name}_bits")
                asm.ldx(asm.dp(R1))
                asm.beq("#{name}_done")
                asm.label("#{name}_bit")
                if way == :left
                  asm.asl(asm.dp(R0))
                  asm.rol(asm.dp(R0 + 2))
                else
                  asm.lda(asm.dp(R0 + 2))
                  asm.cmp(0x8000) # the sign into the carry, to come in at the top
                  asm.ror(asm.dp(R0 + 2))
                  asm.ror(asm.dp(R0))
                end
                asm.dex
                asm.bne("#{name}_bit")
                asm.label("#{name}_done")
                asm.rtl
                asm.label("#{name}_out")
                if way == :left
                  asm.stz(asm.dp(R0))
                else
                  asm.jsr(asm.abs("rt_sign_half"))
                  asm.sta(asm.dp(R0))
                end
                asm.sta(asm.dp(R0 + 2)) if way == :right
                asm.stz(asm.dp(R0 + 2)) if way == :left
                asm.rtl
              end
            end

            # rt_mul_fix: R0 × R1 shifted right R2 places (0 to 32), rounding down, the low 32 bits
            # of that (Int32.mul_fix). The whole product is 64 bits: the two made positive and
            # multiplied a bit at a time into the scratch's wide number, turned round when one of
            # them was negative, then shifted.
            def emit_mul_fix(asm, s)
              p = s.wide
              m = s.addend
              asm.label("rt_mul_fix")
              asm.jsr(asm.abs("rt_make_positive"))
              4.times { |i| asm.stz(asm.dp(p + (2 * i))) }
              asm.lda(asm.dp(R0))
              asm.sta(asm.dp(m))
              asm.lda(asm.dp(R0 + 2))
              asm.sta(asm.dp(m + 2))
              asm.stz(asm.dp(m + 4))
              asm.stz(asm.dp(m + 6))
              asm.label("rt_mul_fix_bit")
              asm.lda(asm.dp(R1))
              asm.ora(asm.dp(R1 + 2))
              asm.beq("rt_mul_fix_product")
              asm.lsr(asm.dp(R1 + 2))
              asm.ror(asm.dp(R1))
              asm.bcc("rt_mul_fix_shift")
              asm.clc
              4.times do |i|
                asm.lda(asm.dp(p + (2 * i)))
                asm.adc(asm.dp(m + (2 * i)))
                asm.sta(asm.dp(p + (2 * i)))
              end
              asm.label("rt_mul_fix_shift")
              asm.asl(asm.dp(m))
              3.times { |i| asm.rol(asm.dp(m + 2 + (2 * i))) }
              asm.bra("rt_mul_fix_bit")
              asm.label("rt_mul_fix_product")
              asm.lda(asm.dp(s.signs))
              asm.eor(asm.dp(s.signs + 1))
              asm.and_a(0x0080)
              asm.beq("rt_mul_fix_shift_right")
              emit_negate_wide(asm, p)
              asm.label("rt_mul_fix_shift_right")
              asm.ldx(asm.dp(R2))
              asm.beq("rt_mul_fix_done")
              asm.label("rt_mul_fix_place")
              asm.lda(asm.dp(p + 6))
              asm.cmp(0x8000)
              3.downto(0) { |i| asm.ror(asm.dp(p + (2 * i))) }
              asm.dex
              asm.bne("rt_mul_fix_place")
              asm.label("rt_mul_fix_done")
              asm.lda(asm.dp(p))
              asm.sta(asm.dp(R0))
              asm.lda(asm.dp(p + 2))
              asm.sta(asm.dp(R0 + 2))
              asm.rtl
            end

            # rt_div_fix: R0 shifted left R2 places (0 to 32), divided by R1, rounded towards nought,
            # and held to the range of a 32-bit number (Int32.div_fix). By nought it is 1, or -1 for
            # a negative numerator. The numerator, made positive, is 64 bits wide once shifted, so
            # the long division takes 64 steps, and the remainder can grow a bit past 32 before the
            # divisor comes off it: that bit, carried out of its top, means the divisor goes in.
            def emit_div_fix(asm, s)
              n = s.wide
              rest = s.rest
              asm.label("rt_div_fix")
              asm.lda(asm.dp(R1))
              asm.ora(asm.dp(R1 + 2))
              asm.bne("rt_div_fix_divide")
              asm.jmp(asm.abs("rt_one_signed_like_r0"))
              asm.label("rt_div_fix_divide")
              asm.jsr(asm.abs("rt_make_positive"))
              asm.lda(asm.dp(R0))
              asm.sta(asm.dp(n))
              asm.lda(asm.dp(R0 + 2))
              asm.sta(asm.dp(n + 2))
              asm.stz(asm.dp(n + 4))
              asm.stz(asm.dp(n + 6))
              asm.ldx(asm.dp(R2))
              asm.beq("rt_div_fix_shifted")
              asm.label("rt_div_fix_widen")
              asm.asl(asm.dp(n))
              3.times { |i| asm.rol(asm.dp(n + 2 + (2 * i))) }
              asm.dex
              asm.bne("rt_div_fix_widen")
              asm.label("rt_div_fix_shifted")
              asm.stz(asm.dp(rest))
              asm.stz(asm.dp(rest + 2))
              asm.ldx(64)
              asm.label("rt_div_fix_bit")
              asm.asl(asm.dp(n))
              3.times { |i| asm.rol(asm.dp(n + 2 + (2 * i))) }
              asm.rol(asm.dp(rest))
              asm.rol(asm.dp(rest + 2))
              asm.bcs("rt_div_fix_take")
              asm.lda(asm.dp(rest))
              asm.cmp(asm.dp(R1))
              asm.lda(asm.dp(rest + 2))
              asm.sbc(asm.dp(R1 + 2))
              asm.bcc("rt_div_fix_no")
              asm.label("rt_div_fix_take")
              asm.sec
              asm.lda(asm.dp(rest))
              asm.sbc(asm.dp(R1))
              asm.sta(asm.dp(rest))
              asm.lda(asm.dp(rest + 2))
              asm.sbc(asm.dp(R1 + 2))
              asm.sta(asm.dp(rest + 2))
              asm.inc(asm.dp(n))
              asm.label("rt_div_fix_no")
              asm.dex
              asm.bne("rt_div_fix_bit")
              # Held to the range: a quotient past 31 bits is the highest number, or for a negative
              # answer, past 2^31 the lowest.
              asm.lda(asm.dp(s.signs))
              asm.eor(asm.dp(s.signs + 1))
              asm.and_a(0x0080)
              asm.bne("rt_div_fix_negative")
              asm.lda(asm.dp(n + 4))
              asm.ora(asm.dp(n + 6))
              asm.bne("rt_div_fix_highest")
              asm.lda(asm.dp(n + 2))
              asm.bmi("rt_div_fix_highest")
              asm.bra("rt_div_fix_answer")
              asm.label("rt_div_fix_highest")
              asm.lda(0xFFFF)
              asm.sta(asm.dp(R0))
              asm.lda(0x7FFF)
              asm.sta(asm.dp(R0 + 2))
              asm.rtl
              asm.label("rt_div_fix_negative")
              asm.lda(asm.dp(n + 4))
              asm.ora(asm.dp(n + 6))
              asm.bne("rt_div_fix_lowest")
              asm.lda(asm.dp(n + 2))
              asm.cmp(0x8000)
              asm.bcc("rt_div_fix_turn")
              asm.bne("rt_div_fix_lowest")
              asm.lda(asm.dp(n))
              asm.bne("rt_div_fix_lowest")
              asm.label("rt_div_fix_turn")
              asm.lda(asm.dp(n))
              asm.sta(asm.dp(R0))
              asm.lda(asm.dp(n + 2))
              asm.sta(asm.dp(R0 + 2))
              asm.jsr(asm.abs("rt_negate_r0"))
              asm.rtl
              asm.label("rt_div_fix_lowest")
              asm.stz(asm.dp(R0))
              asm.lda(0x8000)
              asm.sta(asm.dp(R0 + 2))
              asm.rtl
              asm.label("rt_div_fix_answer")
              asm.lda(asm.dp(n))
              asm.sta(asm.dp(R0))
              asm.lda(asm.dp(n + 2))
              asm.sta(asm.dp(R0 + 2))
              asm.rtl
            end

            # The 64-bit number at +at+ turned round: every bit flipped and one added.
            def emit_negate_wide(asm, at)
              asm.sec
              4.times do |i|
                asm.lda(0)
                asm.sbc(asm.dp(at + (2 * i)))
                asm.sta(asm.dp(at + (2 * i)))
              end
            end

            # The small routines the ones above share, reached with JSR in the same bank:
            #
            #   rt_make_positive     R0 and R1 made positive, their signs kept: the numerator's in the
            #                        scratch's first sign byte and the divisor's in its second, each
            #                        the top byte of the number (bit 7 the sign)
            #   rt_negate_r0         R0 turned round
            #   rt_sign_half         A = $FFFF when R0's high half is negative, $0000 when it is not
            #   rt_one_signed_like_r0   (JMP, ends with RTL) R0 = -1 when it is negative, 1 when not:
            #                        what dividing by nought gives
            def emit_helpers(asm)
              asm.label("rt_one_signed_like_r0")
              asm.lda(asm.dp(R0 + 2))
              asm.bmi("rt_one_signed_like_r0_minus")
              asm.lda(1)
              asm.sta(asm.dp(R0))
              asm.stz(asm.dp(R0 + 2))
              asm.rtl
              asm.label("rt_one_signed_like_r0_minus")
              asm.lda(0xFFFF)
              asm.sta(asm.dp(R0))
              asm.sta(asm.dp(R0 + 2))
              asm.rtl

              asm.label("rt_negate_r0")
              asm.sec
              asm.lda(0)
              asm.sbc(asm.dp(R0))
              asm.sta(asm.dp(R0))
              asm.lda(0)
              asm.sbc(asm.dp(R0 + 2))
              asm.sta(asm.dp(R0 + 2))
              asm.rts

              asm.label("rt_sign_half")
              asm.lda(asm.dp(R0 + 2))
              asm.bmi("rt_sign_half_minus")
              asm.lda(0)
              asm.rts
              asm.label("rt_sign_half_minus")
              asm.lda(0xFFFF)
              asm.rts
            end

            # rt_make_positive needs to know where the signs go, so it is written with the scratch.
            def emit_make_positive(asm, s)
              asm.label("rt_make_positive")
              asm.sep(0x20)
              asm.lda(asm.dp(R0 + 3))
              asm.sta(asm.dp(s.signs))
              asm.lda(asm.dp(R1 + 3))
              asm.sta(asm.dp(s.signs + 1))
              asm.rep(0x20)
              asm.lda(asm.dp(R0 + 2))
              asm.bpl("rt_make_positive_divisor")
              asm.jsr(asm.abs("rt_negate_r0"))
              asm.label("rt_make_positive_divisor")
              asm.lda(asm.dp(R1 + 2))
              asm.bpl("rt_make_positive_done")
              asm.sec
              asm.lda(0)
              asm.sbc(asm.dp(R1))
              asm.sta(asm.dp(R1))
              asm.lda(0)
              asm.sbc(asm.dp(R1 + 2))
              asm.sta(asm.dp(R1 + 2))
              asm.label("rt_make_positive_done")
              asm.rts
            end
          end
        end
      end
    end
  end
end
