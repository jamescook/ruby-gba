# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # A GAME'S ARITHMETIC ON AN 8-BIT PROCESSOR, exactly as IR::Int32 says it: signed 32-bit
          # whole numbers that wrap, a divide by nought that gives 1 or -1, shifts past 31 that empty
          # the number, and fractions multiplied and divided at full width.
          #
          # The SM83 adds and subtracts a byte at a time and does nothing else with numbers, so each
          # of these is a short routine that walks a number's four bytes, carrying from each into
          # the next. Every routine takes and gives its number in four registers, B C D E, with B the
          # top byte (bits 24 to 31) and E the bottom; a second number, where there is one, is four
          # bytes in memory, lowest first, at the address in HL. That is how the stack keeps a number
          # pushed as BC and then DE, so a routine can be handed the one on top of the stack with
          # `ld hl, sp+2` (past its own return address).
          #
          # They use A, HL and the flags as they please, and a few bytes of the processor's own quick
          # memory (Memory::SCRATCH) for the long ones; BC DE is the answer.
          module Int32
            module_function

            # Every routine, written into +asm+, and the quick memory they use (from +memory+).
            # +by_byte+ says the game multiplies by a byte written in the program
            # (Lowering#emit_product_by_byte), which has a routine of its own.
            def emit(asm, memory, by_byte: false)
              s = memory.scratch
              emit_sums(asm)
              emit_compare(asm, s)
              emit_bits(asm)
              emit_multiply(asm, s)
              emit_multiply_by_byte(asm, s) if by_byte
              emit_divide(asm, s)
              emit_shifts(asm)
              emit_fractions(asm, s)
            end

            # BCDE += (HL), -=, &=, |=, ^=.
            def emit_sums(asm)
              { "rt_add32" => %i[add_a adc_a], "rt_sub32" => %i[sub_a sbc_a] }.each do |name, (first, rest)|
                asm.label(name)
                byte_by_byte(asm, first, rest)
                asm.ret
              end
              { "rt_and32" => :and_a, "rt_or32" => :or_a, "rt_xor32" => :xor_a }.each do |name, op|
                asm.label(name)
                byte_by_byte(asm, op, op)
                asm.ret
              end

              # BCDE = -BCDE: nought take it away, borrowing up the bytes.
              asm.label("rt_neg32")
              asm.xor_a(:a)
              asm.sub_a(:e)
              asm.load(:e, :a)
              %i[d c b].each do |reg|
                asm.load(:a, 0)
                asm.sbc_a(reg)
                asm.load(reg, :a)
              end
              asm.ret

              # BCDE = BCDE - 1.
              asm.label("rt_dec32")
              asm.load(:a, :e)
              asm.sub_a(1)
              asm.load(:e, :a)
              %i[d c b].each do |reg|
                asm.load(:a, reg)
                asm.sbc_a(0)
                asm.load(reg, :a)
              end
              asm.ret

              # BCDE = ~BCDE.
              asm.label("rt_not32")
              %i[b c d e].each do |reg|
                asm.load(:a, reg)
                asm.cpl
                asm.load(reg, :a)
              end
              asm.ret

              # BCDE = |BCDE|; the lowest number stays itself, as it does when it wraps.
              asm.label("rt_abs32")
              asm.bit(7, :b)
              asm.ret(:z)
              asm.jump("rt_neg32")
            end

            # One byte of BCDE at a time against (HL), lowest first: the first with +first+, the rest
            # with +rest+ (the carrying form of the same sum).
            def byte_by_byte(asm, first, rest)
              %i[e d c b].each_with_index do |reg, i|
                asm.load(:a, reg)
                asm.public_send(i.zero? ? first : rest, [:hl])
                asm.load(reg, :a)
                asm.inc(:hl) unless reg == :b
              end
            end

            # COMPARING TWO SIGNED NUMBERS: BCDE against (HL), leaving both as they were and the
            # answer in A — 0 when they are equal, 1 when BCDE is the smaller, 2 when it is the larger
            # — with the zero flag set only for equal. A caller asks `cp 1` and so on.
            #
            # A signed comparison is an unsigned one with the top bit of each number turned over: that
            # puts the negative numbers, whose top bit is set, below the positive ones. Subtracting the
            # two a byte at a time leaves the carry set exactly when the first was below the second.
            def emit_compare(asm, s)
              # Unsigned: BCDE and (HL) as numbers from nought to 2^32 - 1, which a number below
              # nought is past the top of — so one comparison asks whether a number is from nought
              # up to a size.
              asm.label("rt_cmpu32")
              asm.push(:bc)
              asm.push(:de)
              asm.load(:a, :e)
              asm.sub_a([:hl])
              asm.load(:e, :a)
              asm.inc(:hl)
              asm.load(:a, :d)
              asm.sbc_a([:hl])
              asm.load(:d, :a)
              asm.inc(:hl)
              asm.load(:a, :c)
              asm.sbc_a([:hl])
              asm.load(:c, :a)
              asm.inc(:hl)
              asm.load(:a, :b)
              asm.sbc_a([:hl])
              asm.jump_relative(:c, "rt_cmp32_less")
              asm.or_a(:c)
              asm.or_a(:d)
              asm.or_a(:e)
              asm.pop(:de)
              asm.pop(:bc)
              asm.ret(:z)
              asm.load(:a, 2)
              asm.or_a(:a)
              asm.ret

              asm.label("rt_cmp32")
              asm.push(:bc)
              asm.push(:de)
              asm.push(:hl)
              3.times { asm.inc(:hl) }
              asm.load(:a, [:hl])
              asm.xor_a(0x80)
              asm.load_high(s.cmp_top, :a)
              asm.pop(:hl)
              asm.load(:a, :b)
              asm.xor_a(0x80)
              asm.load(:b, :a)
              asm.load(:a, :e)
              asm.sub_a([:hl])
              asm.load(:e, :a)
              asm.inc(:hl)
              asm.load(:a, :d)
              asm.sbc_a([:hl])
              asm.load(:d, :a)
              asm.inc(:hl)
              asm.load(:a, :c)
              asm.sbc_a([:hl])
              asm.load(:c, :a)
              asm.load(:hl, s.cmp_top) # a load moves no flag, so the carry from the byte below is kept
              asm.load(:a, :b)
              asm.sbc_a([:hl])
              asm.jump_relative(:c, "rt_cmp32_less")
              asm.or_a(:c)
              asm.or_a(:d)
              asm.or_a(:e)
              asm.pop(:de)
              asm.pop(:bc)
              asm.ret(:z) # A is nought, and so is the flag: equal
              asm.load(:a, 2)
              asm.or_a(:a) # the zero flag clear
              asm.ret
              asm.label("rt_cmp32_less")
              asm.pop(:de)
              asm.pop(:bc)
              asm.load(:a, 1)
              asm.or_a(:a)
              asm.ret

              # BCDE = 1 when the zero flag is set, 0 when not; and the other way round.
              asm.label("rt_bool_of_z")
              asm.load(:bc, 0)
              asm.load(:de, 0)
              asm.ret(:nz)
              asm.inc(:e)
              asm.ret
              asm.label("rt_bool_of_nz")
              asm.load(:bc, 0)
              asm.load(:de, 0)
              asm.ret(:z)
              asm.inc(:e)
              asm.ret

              # Z set when BCDE is nought.
              asm.label("rt_test32")
              asm.load(:a, :b)
              asm.or_a(:c)
              asm.or_a(:d)
              asm.or_a(:e)
              asm.ret
            end

            # BCDE = (BCDE != 0) & ((HL) != 0), and the same with |: both sides already worked out,
            # as the interpreter works them out, so nothing is skipped.
            def emit_bits(asm)
              %w[rt_both32 rt_either32].each do |name|
                asm.label(name)
                asm.call("rt_test32")
                asm.load(:a, 0)
                asm.jump_relative(:z, "#{name}_left")
                asm.inc(:a)
                asm.label("#{name}_left") # A = 1 when the number on the left is not nought
                asm.load(:e, :a)
                asm.load(:a, [:hli])
                asm.or_a([:hl])
                asm.inc(:hl)
                asm.or_a([:hl])
                asm.inc(:hl)
                asm.or_a([:hl])
                asm.load(:a, 0)
                asm.jump_relative(:z, "#{name}_right")
                asm.inc(:a)
                asm.label("#{name}_right") # A = 1 when the number on the right is not nought
                name == "rt_both32" ? asm.and_a(:e) : asm.or_a(:e)
                asm.load(:e, :a)
                asm.load(:bc, 0)
                asm.load(:d, 0)
                asm.ret
              end
            end

            # BCDE = BCDE × A, A a byte from 1 to 255: the same long multiplication as rt_mul32, with
            # the byte walked in a register rather than four bytes of memory, so a number times a
            # small count — a row of poses times how many poses — is a few turns of a short loop.
            def emit_multiply_by_byte(asm, s)
              asm.label("rt_mul32_byte")
              asm.load(:l, :a)
              asm.xor_a(:a)
              4.times { |i| asm.load_high(s.product + i, :a) }
              asm.label("rt_mul32_byte_loop")
              asm.srl(:l)
              asm.jump_relative(:nc, "rt_mul32_byte_shift")
              %i[e d c b].each_with_index do |reg, i|
                asm.load_high(:a, s.product + i)
                i.zero? ? asm.add_a(reg) : asm.adc_a(reg)
                asm.load_high(s.product + i, :a)
              end
              asm.label("rt_mul32_byte_shift")
              asm.load(:a, :l)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_mul32_byte_done")
              asm.sla(:e)
              asm.rl(:d)
              asm.rl(:c)
              asm.rl(:b)
              asm.jump_relative("rt_mul32_byte_loop")
              asm.label("rt_mul32_byte_done")
              %i[e d c b].each_with_index do |reg, i|
                asm.load_high(:a, s.product + i)
                asm.load(reg, :a)
              end
              asm.ret
            end

            # BCDE = BCDE × (HL), the low 32 bits of the product, which is what a signed product
            # wraps to as well. A long multiplication in binary: for every bit of the second number,
            # the first is added in where that bit is set, shifted along by where the bit is. It stops
            # as soon as no bits are left, so multiplying by a small number is quick.
            def emit_multiply(asm, s)
              asm.label("rt_mul32")
              4.times do |i|
                asm.load(:a, [:hli])
                asm.load_high(s.mul_by + i, :a)
              end
              # The smaller of the two, taken as whole numbers of 32 bits, is the one walked bit by
              # bit: the product is the same either way round, and a test times a number (one or
              # nought times what was read) is then one turn of the loop rather than one a bit.
              %i[b c d].each_with_index do |reg, i|
                asm.load_high(:a, s.mul_by + 3 - i)
                asm.cp_a(reg)
                asm.jump_relative(:c, "rt_mul32_ready")
                asm.jump_relative(:nz, "rt_mul32_swap")
              end
              asm.load_high(:a, s.mul_by)
              asm.cp_a(:e)
              asm.jump_relative(:c, "rt_mul32_ready")
              asm.jump_relative(:z, "rt_mul32_ready")
              asm.label("rt_mul32_swap")
              %i[e d c b].each_with_index do |reg, i|
                asm.load_high(:a, s.mul_by + i)
                asm.load(:l, :a)
                asm.load(:a, reg)
                asm.load_high(s.mul_by + i, :a)
                asm.load(reg, :l)
              end
              asm.label("rt_mul32_ready")
              asm.xor_a(:a)
              4.times { |i| asm.load_high(s.product + i, :a) }
              asm.label("rt_mul32_loop")
              asm.load_high(:a, s.mul_by)
              (1..3).each do |i|
                asm.load(:l, :a)
                asm.load_high(:a, s.mul_by + i)
                asm.or_a(:l)
              end
              asm.jump_relative(:z, "rt_mul32_done")
              asm.load(:hl, s.mul_by + 3)
              asm.srl([:hl])
              3.times do
                asm.dec(:hl)
                asm.rr([:hl])
              end
              asm.jump_relative(:nc, "rt_mul32_shift")
              asm.load(:hl, s.product)
              %i[e d c b].each_with_index do |reg, i|
                asm.load(:a, [:hl])
                i.zero? ? asm.add_a(reg) : asm.adc_a(reg)
                asm.load(i == 3 ? [:hl] : [:hli], :a)
              end
              asm.label("rt_mul32_shift")
              asm.sla(:e)
              asm.rl(:d)
              asm.rl(:c)
              asm.rl(:b)
              asm.jump_relative("rt_mul32_loop")
              asm.label("rt_mul32_done")
              load_bcde_from_quick(asm, s.product)
              asm.ret
            end

            # DIVISION AND REMAINDER, as IR::Int32 has them: a quotient cut toward nought, a remainder
            # with the sign of the number divided BY (the way Ruby's % works), a divide by nought
            # that gives 1 (or -1 for a number below nought) and a remainder by nought that gives the
            # number back.
            #
            # Both are worked out on the sizes of the two numbers, by the long division a person does
            # on paper, a binary digit at a time (rt_udiv32), and given their signs afterwards.
            def emit_divide(asm, s)
              # Unsigned: dividend (s.div_n) ÷ divisor (s.div_d), quotient left in s.div_n and
              # remainder in s.div_r. Thirty-two times round: shift the next digit of the dividend
              # into the remainder, and take the divisor off it where it goes.
              asm.label("rt_udiv32")
              asm.xor_a(:a)
              4.times { |i| asm.load_high(s.div_r + i, :a) }
              asm.load(:b, 32)
              # A dividend's top byte of nought gives eight digits of nought and moves nothing into
              # the remainder, so it is skipped a byte at a time: the small numbers games divide
              # most take eight turns of the loop rather than thirty-two.
              asm.label("rt_udiv32_skip")
              asm.load_high(:a, s.div_n + 3)
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_udiv32_loop")
              asm.load(:a, :b)
              asm.cp_a(8)
              asm.jump_relative(:z, "rt_udiv32_loop")
              [2, 1, 0].each do |i|
                asm.load_high(:a, s.div_n + i)
                asm.load_high(s.div_n + i + 1, :a)
              end
              asm.xor_a(:a)
              asm.load_high(s.div_n, :a)
              asm.load(:a, :b)
              asm.sub_a(8)
              asm.load(:b, :a)
              asm.jump_relative("rt_udiv32_skip")
              # Sixteen digits or fewer left and a divisor under 65536: the same long division in
              # the processor's own 16-bit pairs (rt_udiv16), at a third of the cost.
              asm.label("rt_udiv32_loop")
              asm.load(:a, :b)
              asm.cp_a(17)
              asm.jump_relative(:nc, "rt_udiv32_digit")
              asm.load_high(:a, s.div_d + 2)
              asm.load(:l, :a)
              asm.load_high(:a, s.div_d + 3)
              asm.or_a(:l)
              asm.jump(:z, "rt_udiv16")
              asm.label("rt_udiv32_digit")
              asm.load(:hl, s.div_n)
              asm.sla([:hl])
              3.times do
                asm.inc(:hl)
                asm.rl([:hl])
              end
              asm.load(:hl, s.div_r) # a load moves no flag: the top digit carries into the remainder
              asm.rl([:hl])
              3.times do
                asm.inc(:hl)
                asm.rl([:hl])
              end
              asm.load(:hl, s.div_d)
              asm.load_high(:a, s.div_r)
              asm.sub_a([:hl])
              asm.load(:e, :a)
              asm.inc(:hl)
              asm.load_high(:a, s.div_r + 1)
              asm.sbc_a([:hl])
              asm.load(:d, :a)
              asm.inc(:hl)
              asm.load_high(:a, s.div_r + 2)
              asm.sbc_a([:hl])
              asm.load(:c, :a)
              asm.inc(:hl)
              asm.load_high(:a, s.div_r + 3)
              asm.sbc_a([:hl])
              asm.jump_relative(:c, "rt_udiv32_next") # the divisor does not go: this digit of the quotient is 0
              asm.load_high(s.div_r + 3, :a)
              asm.load(:a, :c)
              asm.load_high(s.div_r + 2, :a)
              asm.load(:a, :d)
              asm.load_high(s.div_r + 1, :a)
              asm.load(:a, :e)
              asm.load_high(s.div_r, :a)
              asm.load(:hl, s.div_n)
              asm.set(0, [:hl])
              asm.label("rt_udiv32_next")
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_udiv32_digit")
              asm.ret

              # The last B digits (16 or fewer) of the dividend, in s.div_n's top two bytes, over a
              # divisor of 16 bits: HL is the dividend shifting out at the top and the quotient
              # coming in at the bottom, BC the remainder, DE the divisor.
              asm.label("rt_udiv16")
              asm.load(:a, :b)
              asm.load_high(s.cmp_top, :a) # the count; nothing here compares
              asm.load_high(:a, s.div_n + 2)
              asm.load(:l, :a)
              asm.load_high(:a, s.div_n + 3)
              asm.load(:h, :a)
              asm.load_high(:a, s.div_d)
              asm.load(:e, :a)
              asm.load_high(:a, s.div_d + 1)
              asm.load(:d, :a)
              asm.load(:bc, 0)
              asm.label("rt_udiv16_loop")
              asm.add_hl(:hl)
              asm.rl(:c)
              asm.rl(:b)
              asm.load(:a, :c)
              asm.sub_a(:e)
              asm.load(:c, :a)
              asm.load(:a, :b)
              asm.sbc_a(:d)
              asm.load(:b, :a)
              asm.jump_relative(:nc, "rt_udiv16_goes")
              asm.load(:a, :c) # it does not go: the remainder back as it was
              asm.add_a(:e)
              asm.load(:c, :a)
              asm.load(:a, :b)
              asm.adc_a(:d)
              asm.load(:b, :a)
              asm.jump_relative("rt_udiv16_next")
              asm.label("rt_udiv16_goes")
              asm.inc(:l)
              asm.label("rt_udiv16_next")
              asm.load_high(:a, s.cmp_top)
              asm.dec(:a)
              asm.load_high(s.cmp_top, :a)
              asm.jump_relative(:nz, "rt_udiv16_loop")
              asm.xor_a(:a)
              [[s.div_n, :l, :h], [s.div_r, :c, :b]].each do |at, low, high|
                asm.load_high(at + 2, :a)
                asm.load_high(at + 3, :a)
                asm.load(:a, low)
                asm.load_high(at, :a)
                asm.load(:a, high)
                asm.load_high(at + 1, :a)
                asm.xor_a(:a)
              end
              asm.ret

              # The two numbers' sizes into s.div_n and s.div_d, and their signs into s.sign_n and
              # s.sign_d (0x80 for below nought). BCDE is the dividend, (HL) the divisor.
              asm.label("rt_div_setup")
              asm.load(:a, :b)
              asm.and_a(0x80)
              asm.load_high(s.sign_n, :a)
              asm.push(:hl)
              asm.call("rt_abs32")
              store_bcde_to_quick(asm, s.div_n)
              asm.pop(:hl)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:a, [:hli])
              asm.load(:d, :a)
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:b, [:hl])
              asm.load(:a, :b)
              asm.and_a(0x80)
              asm.load_high(s.sign_d, :a)
              asm.call("rt_abs32")
              store_bcde_to_quick(asm, s.div_d)
              asm.call("rt_test32") # Z: the divisor is nought
              asm.ret

              # BCDE = BCDE ÷ (HL).
              asm.label("rt_div32")
              asm.call("rt_div_setup")
              asm.jump_relative(:nz, "rt_div32_divide")
              asm.load_high(:a, s.sign_n) # by nought: 1, or -1 for a number below nought
              asm.or_a(:a)
              asm.load(:bc, 0)
              asm.load(:de, 1)
              asm.ret(:z)
              asm.load(:bc, 0xFFFF)
              asm.load(:de, 0xFFFF)
              asm.ret
              asm.label("rt_div32_divide")
              asm.call("rt_udiv32")
              load_bcde_from_quick(asm, s.div_n)
              asm.load_high(:a, s.sign_n)
              asm.load(:l, :a)
              asm.load_high(:a, s.sign_d)
              asm.xor_a(:l)
              asm.ret(:z) # the same signs: the quotient is above nought
              asm.jump("rt_neg32")

              # BCDE = BCDE % (HL).
              asm.label("rt_mod32")
              asm.push(:bc)
              asm.push(:de)
              asm.call("rt_div_setup")
              asm.jump_relative(:nz, "rt_mod32_divide")
              asm.pop(:de) # by nought: the number itself
              asm.pop(:bc)
              asm.ret
              asm.label("rt_mod32_divide")
              asm.add_sp(4)
              asm.call("rt_udiv32")
              load_bcde_from_quick(asm, s.div_r)
              asm.call("rt_test32")
              asm.jump_relative(:z, "rt_mod32_sign") # nothing over: nought either way
              asm.load_high(:a, s.sign_n)
              asm.load(:l, :a)
              asm.load_high(:a, s.sign_d)
              asm.xor_a(:l)
              asm.jump_relative(:z, "rt_mod32_sign")
              # The signs differ: what is over is counted back from the divisor's size.
              asm.call("rt_neg32")
              asm.load(:hl, s.div_d)
              asm.call("rt_add32")
              asm.label("rt_mod32_sign")
              asm.load_high(:a, s.sign_d) # the answer takes the divisor's sign
              asm.or_a(:a)
              asm.ret(:z)
              asm.jump("rt_neg32")
            end

            # SHIFTS. BCDE << (HL) and BCDE >> (HL), the second keeping the sign. A count below
            # nought or past 31 empties the number: to nought, or to -1 for a number below nought
            # shifted right.
            def emit_shifts(asm)
              asm.label("rt_shift_count") # A = the count, and C (the flag) set when it is out of range
              asm.inc(:hl)
              asm.load(:a, [:hli])
              asm.or_a([:hl])
              asm.inc(:hl)
              asm.or_a([:hl])
              asm.dec(:hl)
              asm.dec(:hl)
              asm.dec(:hl)
              asm.scf
              asm.ret(:nz) # the count's upper bytes say it is past 255 or below nought
              asm.load(:a, [:hl])
              asm.cp_a(32)
              asm.ccf
              asm.ret # the flag set from 32 up

              asm.label("rt_shl32")
              asm.call("rt_shift_count")
              asm.jump_relative(:c, "rt_shift_empty")
              asm.label("rt_shl32_by_a")
              asm.or_a(:a)
              asm.ret(:z)
              asm.label("rt_shl32_loop")
              asm.sla(:e)
              asm.rl(:d)
              asm.rl(:c)
              asm.rl(:b)
              asm.dec(:a)
              asm.jump_relative(:nz, "rt_shl32_loop")
              asm.ret
              asm.label("rt_shift_empty")
              asm.load(:bc, 0)
              asm.load(:de, 0)
              asm.ret

              asm.label("rt_shr32")
              asm.call("rt_shift_count")
              asm.jump_relative(:nc, "rt_shr32_by_a")
              asm.bit(7, :b)
              asm.jump_relative(:z, "rt_shift_empty")
              asm.load(:bc, 0xFFFF)
              asm.load(:de, 0xFFFF)
              asm.ret
              asm.label("rt_shr32_by_a")
              asm.or_a(:a)
              asm.ret(:z)
              asm.label("rt_shr32_loop")
              asm.sra(:b)
              asm.rr(:c)
              asm.rr(:d)
              asm.rr(:e)
              asm.dec(:a)
              asm.jump_relative(:nz, "rt_shr32_loop")
              asm.ret
            end

            # NUMBERS WITH A FRACTION, kept as whole numbers with +bits+ of fraction below the point.
            # Multiplying two such numbers makes one with twice the bits of fraction, so the product
            # is worked out at its full 64 bits and shifted back down; dividing shifts the dividend
            # up first. The fraction's bit count is the number on top of the stack (HL+4 below the
            # second number, as the caller pushes them).
            #
            # rt_mul_fix: BCDE = (BCDE × (HL)) >> (HL+4), the shift keeping the sign, as IR::Int32's.
            # rt_div_fix: BCDE = (BCDE << bits) ÷ (HL), cut toward nought and held between the
            # lowest and highest whole numbers, 1 or -1 when divided by nought.
            def emit_fractions(asm, s)
              asm.label("rt_mul_fix")
              # The fraction's bits first, from below the second number.
              asm.push(:hl)
              4.times { asm.inc(:hl) }
              asm.load(:a, [:hl])
              asm.load_high(s.fraction_bits, :a)
              asm.pop(:hl)
              asm.call("rt_div_setup") # the sizes and signs, which are what a product needs too
              # The 64-bit product of the sizes, in s.wide: s.div_d is the multiplier, walked a bit at
              # a time; s.div_n, widened to 64 bits in s.wide_by, is shifted up as it goes.
              asm.xor_a(:a)
              8.times { |i| asm.load_high(s.wide + i, :a) }
              4.times do |i|
                asm.load_high(:a, s.div_n + i)
                asm.load_high(s.wide_by + i, :a)
              end
              asm.xor_a(:a)
              4.times { |i| asm.load_high(s.wide_by + 4 + i, :a) }
              asm.load(:b, 32)
              asm.label("rt_mul_fix_loop")
              asm.load(:hl, s.div_d + 3)
              asm.srl([:hl])
              3.times do
                asm.dec(:hl)
                asm.rr([:hl])
              end
              asm.jump_relative(:nc, "rt_mul_fix_shift")
              add_quick64(asm, s.wide, s.wide_by)
              asm.label("rt_mul_fix_shift")
              asm.load(:hl, s.wide_by)
              asm.sla([:hl])
              7.times do
                asm.inc(:hl)
                asm.rl([:hl])
              end
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_mul_fix_loop")
              # The product's sign, then shifted down by the fraction's bits, keeping the sign, so a
              # number below nought rounds down as the arithmetic shift does.
              asm.load_high(:a, s.sign_n)
              asm.load(:l, :a)
              asm.load_high(:a, s.sign_d)
              asm.xor_a(:l)
              asm.call(:nz, "rt_neg64")
              asm.load_high(:a, s.fraction_bits)
              asm.or_a(:a)
              asm.jump_relative(:z, "rt_mul_fix_low")
              asm.load(:b, :a)
              asm.label("rt_mul_fix_down")
              asm.load(:hl, s.wide + 7)
              asm.sra([:hl])
              7.times do
                asm.dec(:hl)
                asm.rr([:hl])
              end
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_mul_fix_down")
              asm.label("rt_mul_fix_low")
              load_bcde_from_quick(asm, s.wide)
              asm.ret

              # The 64-bit number in s.wide, turned to below nought (or back).
              asm.label("rt_neg64")
              asm.load(:hl, s.wide)
              asm.xor_a(:a)
              asm.sub_a([:hl])
              asm.load([:hli], :a)
              7.times do |i|
                asm.load(:a, 0)
                asm.sbc_a([:hl])
                i == 6 ? asm.load([:hl], :a) : asm.load([:hli], :a)
              end
              asm.ret

              asm.label("rt_div_fix")
              asm.push(:hl)
              4.times { asm.inc(:hl) }
              asm.load(:a, [:hl])
              asm.load_high(s.fraction_bits, :a)
              asm.pop(:hl)
              asm.call("rt_div_setup")
              asm.jump_relative(:nz, "rt_div_fix_divide")
              # By nought: the widened dividend's sign decides, and widening never changes a sign.
              asm.load_high(:a, s.sign_n)
              asm.or_a(:a)
              asm.load(:bc, 0)
              asm.load(:de, 1)
              asm.ret(:z)
              asm.load(:bc, 0xFFFF)
              asm.load(:de, 0xFFFF)
              asm.ret
              asm.label("rt_div_fix_divide")
              # The dividend's size widened to 64 bits and shifted up by the fraction's bits.
              4.times do |i|
                asm.load_high(:a, s.div_n + i)
                asm.load_high(s.wide + i, :a)
              end
              asm.xor_a(:a)
              4.times { |i| asm.load_high(s.wide + 4 + i, :a) }
              asm.load_high(:a, s.fraction_bits)
              asm.or_a(:a)
              asm.jump_relative(:z, "rt_div_fix_long")
              asm.load(:b, :a)
              asm.label("rt_div_fix_up")
              asm.load(:hl, s.wide)
              asm.sla([:hl])
              7.times do
                asm.inc(:hl)
                asm.rl([:hl])
              end
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_div_fix_up")
              # Long division, 64 digits: the quotient builds in s.wide as its digits move out.
              asm.label("rt_div_fix_long")
              asm.xor_a(:a)
              4.times { |i| asm.load_high(s.div_r + i, :a) }
              asm.load_high(s.div_r_top, :a)
              asm.load(:b, 64)
              asm.label("rt_div_fix_loop")
              asm.load(:hl, s.wide)
              asm.sla([:hl])
              7.times do
                asm.inc(:hl)
                asm.rl([:hl])
              end
              asm.load(:hl, s.div_r)
              asm.rl([:hl])
              3.times do
                asm.inc(:hl)
                asm.rl([:hl])
              end
              # The remainder can reach 33 bits before the divisor comes off it: its top bit is kept
              # apart, and when it is set the divisor always goes.
              asm.load(:a, 0)
              asm.rla
              asm.load_high(s.div_r_top, :a)
              asm.load(:hl, s.div_d)
              asm.load_high(:a, s.div_r)
              asm.sub_a([:hl])
              asm.load(:e, :a)
              asm.inc(:hl)
              asm.load_high(:a, s.div_r + 1)
              asm.sbc_a([:hl])
              asm.load(:d, :a)
              asm.inc(:hl)
              asm.load_high(:a, s.div_r + 2)
              asm.sbc_a([:hl])
              asm.load(:c, :a)
              asm.inc(:hl)
              asm.load_high(:a, s.div_r + 3)
              asm.sbc_a([:hl])
              asm.load(:h, :a)
              asm.load_high(:a, s.div_r_top)
              asm.sbc_a(0)
              asm.jump_relative(:c, "rt_div_fix_next")
              asm.load(:a, :h)
              asm.load_high(s.div_r + 3, :a)
              asm.load(:a, :c)
              asm.load_high(s.div_r + 2, :a)
              asm.load(:a, :d)
              asm.load_high(s.div_r + 1, :a)
              asm.load(:a, :e)
              asm.load_high(s.div_r, :a)
              asm.load(:hl, s.wide)
              asm.set(0, [:hl])
              asm.label("rt_div_fix_next")
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_div_fix_loop")
              # Held to what a whole number can be: past 2^31 - 1 above nought, past 2^31 below it.
              asm.load_high(:a, s.sign_n)
              asm.load(:l, :a)
              asm.load_high(:a, s.sign_d)
              asm.xor_a(:l)
              asm.jump_relative(:nz, "rt_div_fix_below")
              asm.call("rt_wide_fits_31")
              asm.jump_relative(:nc, "rt_div_fix_most")
              load_bcde_from_quick(asm, s.wide)
              asm.ret
              asm.label("rt_div_fix_most")
              asm.load(:bc, 0x7FFF)
              asm.load(:de, 0xFFFF)
              asm.ret
              asm.label("rt_div_fix_below")
              # Below nought the size can be 2^31 exactly, which is the lowest number itself.
              asm.call("rt_wide_fits_32")
              asm.jump_relative(:nc, "rt_div_fix_least")
              load_bcde_from_quick(asm, s.wide)
              asm.jump("rt_neg32") # a size of 2^31 or less is at or above the lowest number once turned
              asm.label("rt_div_fix_least")
              asm.load(:bc, 0x8000)
              asm.load(:de, 0)
              asm.ret

              # Carry set when s.wide is below 2^31 (fits a number above nought).
              asm.label("rt_wide_fits_31")
              asm.call("rt_wide_top_empty")
              asm.ret(:nz) # NZ: the top half has something in it, and the carry is clear
              asm.load_high(:a, s.wide + 3)
              asm.cp_a(0x80)
              asm.ret # carry when below 0x80
              # Carry set when s.wide is at most 2^31.
              asm.label("rt_wide_fits_32")
              asm.call("rt_wide_top_empty")
              asm.ret(:nz)
              asm.load_high(:a, s.wide + 3)
              asm.cp_a(0x80)
              asm.ret(:c)
              asm.ret(:nz) # above 0x80: too big, carry clear
              asm.load_high(:a, s.wide + 2) # exactly 0x80 on top: fits only when everything below is nought
              asm.load(:l, :a)
              asm.load_high(:a, s.wide + 1)
              asm.or_a(:l)
              asm.load(:l, :a)
              asm.load_high(:a, s.wide)
              asm.or_a(:l)
              asm.ret(:nz) # carry is clear: too big
              asm.scf
              asm.ret
              # Z set (and carry clear) when s.wide's top four bytes are nought.
              asm.label("rt_wide_top_empty")
              asm.load_high(:a, s.wide + 4)
              asm.load(:l, :a)
              3.times do |i|
                asm.load_high(:a, s.wide + 5 + i)
                asm.or_a(:l)
                asm.load(:l, :a)
              end
              asm.or_a(:a)
              asm.ret
            end

            # s.a += s.b, both 64 bits in quick memory.
            def add_quick64(asm, sum, addend)
              8.times do |i|
                asm.load_high(:a, addend + i)
                asm.load(:l, :a)
                asm.load_high(:a, sum + i)
                i.zero? ? asm.add_a(:l) : asm.adc_a(:l)
                asm.load_high(sum + i, :a)
              end
            end

            def load_bcde_from_quick(asm, at)
              %i[e d c b].each_with_index do |reg, i|
                asm.load_high(:a, at + i)
                asm.load(reg, :a)
              end
            end

            def store_bcde_to_quick(asm, at)
              %i[e d c b].each_with_index do |reg, i|
                asm.load(:a, reg)
                asm.load_high(at + i, :a)
              end
            end
          end
        end
      end
    end
  end
end
