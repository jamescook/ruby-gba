# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        class Lowering
          # SUMS WITH A NUMBER WRITTEN IN THE PROGRAM, worked out where the number is rather than by
          # the runtime's routines. Mixed into Lowering.
          #
          # The Color's processor works on a byte at a time, so the runtime's routine for a sum
          # walks all four bytes of both numbers, and its shift goes a bit at a time round a loop.
          # When one side is a number written in the program, most of that work is known before
          # the game runs:
          #
          # - A SHIFT by a whole number of bytes is each byte moved into the register beside it,
          #   which is what a shift by 8 is on a byte-wide processor: x >> 8, a place kept in 256ths
          #   of a pixel made a whole pixel, is four loads rather than eight trips round a loop.
          #   What is left of the count is a few single shifts.
          # - AND, OR and XOR with such a number are a byte of it to each byte of the other: an
          #   AND with 0x00 is nought, one with 0xFF is the byte as it is, and only the rest need
          #   the instruction.
          # - An AND that keeps only the low one or two bytes (x & 0xFFFF, the two bytes a place
          #   wraps in) needs only those bytes of x, so x is worked out at that width (#low_value):
          #   a variable's two bytes read where it is kept, a sum two bytes wide.
          # - A COMPARISON with such a number is the subtraction rt_cmp32 does, its bytes written
          #   into the instructions, so the carry says the answer.
          #
          # What every number means is unchanged: these give IR::Int32's answer, as the runtime's
          # routines do.
          module WrittenNumbers
            private

            # +node+, a shift by a count written in the program, worked out in BCDE: true when it
            # was done so.
            def emit_shift_by_written_count(node)
              count = folded(node.rhs)
              return false unless count

              value(node.lhs)
              emit_shift_in_place(node.op, count)
              true
            end

            # BCDE shifted left (:<<) or right (:>>, the sign filling in behind) by +count+, as
            # IR::Int32 shifts: a count below nought or from 32 up empties the number.
            def emit_shift_in_place(op, count)
              unless Int32.shift_count_in_range?(count)
                return op == :<< ? load_constant(0) : emit_sign_in_every_byte
              end

              bytes, bits = count.divmod(8)
              op == :<< ? emit_bytes_moved_up(bytes) : emit_bytes_moved_down(bytes)
              emit_bits_shifted(op, bits, bytes)
            end

            # Each byte of BCDE moved +bytes+ places toward the top, the bottom ones nought; the
            # top byte first, since each takes the one below it.
            def emit_bytes_moved_up(bytes)
              return if bytes.zero?

              3.downto(0) do |i|
                from = i - bytes
                @asm.load(BCDE_LOW_FIRST[i], from.negative? ? 0 : BCDE_LOW_FIRST[from])
              end
            end

            # Each byte of BCDE moved +bytes+ places toward the bottom, the top ones the sign; the
            # bottom byte first. The sign is made from B before B is moved.
            def emit_bytes_moved_down(bytes)
              return if bytes.zero?

              emit_sign_in_a
              (0..3).each do |i|
                from = i + bytes
                @asm.load(BCDE_LOW_FIRST[i], from > 3 ? :a : BCDE_LOW_FIRST[from])
              end
            end

            # The rest of a shift, under a byte. The bytes moved past are nought (left) or the sign
            # (right) already, and stay so, so only the others are shifted, the carry walking from
            # one to the next. More than a few bits go round the runtime's loop instead.
            def emit_bits_shifted(op, bits, bytes_moved)
              return if bits.zero?

              live = BCDE_LOW_FIRST.length - bytes_moved
              if bits * live > 12
                @asm.load(:a, bits)
                return @asm.call(op == :<< ? "rt_shl32_by_a" : "rt_shr32_by_a")
              end

              bits.times do
                if op == :<<
                  first, *rest = BCDE_LOW_FIRST.drop(bytes_moved)
                  @asm.sla(first)
                  rest.each { |register| @asm.rl(register) }
                else
                  first, *rest = BCDE_LOW_FIRST.first(live).reverse
                  @asm.sra(first)
                  rest.each { |register| @asm.rr(register) }
                end
              end
            end

            # A = 0x00 for a number in BCDE at or above nought, 0xFF for one below it.
            def emit_sign_in_a
              @asm.load(:a, :b)
              @asm.rla # the carry is the sign bit
              @asm.sbc_a(:a)
            end

            def emit_sign_in_every_byte
              emit_sign_in_a
              BCDE_LOW_FIRST.each { |register| @asm.load(register, :a) }
            end

            # +node+, an AND, OR or XOR with a number written in the program, worked out a byte of
            # the number to each byte of the other side: true when it was done so. An AND that
            # keeps only the low bytes works the other side out only that wide.
            def emit_bitwise_with_written_number(node)
              [[node.rhs, node.lhs], [node.lhs, node.rhs]].each do |by, other|
                number = folded(by)
                next unless number

                number &= 0xFFFF_FFFF
                node.op == :& ? low_value(other, bytes_kept(number)) : value(other)
                BCDE_LOW_FIRST.each_with_index { |register, i| emit_byte_bitwise(node.op, register, (number >> (8 * i)) & 0xFF) }
                return true
              end
              false
            end

            # +node+, a product one side of which can only be a byte — ANDed with a byte written in
            # the program, or read from a table kept a byte to an entry without its sign — by
            # rt_mul32_byte, that side handed over in A: true when it was done so. A speed times a
            # sine kept in 256ths is such a product.
            def emit_product_by_byte_value(node)
              [[node.rhs, node.lhs], [node.lhs, node.rhs]].each do |by, other|
                next unless byte_valued?(by)

                value(by)
                @asm.load(:a, :e)
                @asm.push(:af)
                value(other)
                @asm.pop(:af)
                @asm.call("rt_mul32_byte")
                return true
              end
              false
            end

            def byte_valued?(node)
              return false unless node.is_a?(Node)
              return [node.lhs, node.rhs].any? { |side| folded(side)&.between?(0, 0xFF) } if binop?(node, :&)

              node.kind == :table_get && @tables.key?(node.name) && table_keeping(@tables.fetch(node.name)) == [1, false]
            end

            # How many of a number's low bytes an AND with +mask+ keeps: up to its highest byte
            # that is not nought.
            def bytes_kept(mask) = [(mask.bit_length + 7) / 8, 1].max

            # +register+ AND, OR or XOR the byte +byte+, in place.
            def emit_byte_bitwise(op, register, byte)
              case [op, byte]
              in [:&, 0xFF] | [:|, 0] | [:^, 0] then nil
              in [:&, 0] then @asm.load(register, 0)
              in [:|, 0xFF] then @asm.load(register, 0xFF)
              else
                @asm.load(:a, register)
                { :& => :and_a, :| => :or_a, :^ => :xor_a }.fetch(op).then { |sum| @asm.public_send(sum, byte) }
                @asm.load(register, :a)
              end
            end

            # THE LOW +bytes+ BYTES OF +operand+'s NUMBER, in E (and D for two), the registers above
            # them holding anything: what a caller keeping only those bytes needs (an AND with
            # 0xFFFF). The low bytes of a sum, an AND, an OR or an XOR come from the low bytes of
            # its two sides alone, so each side is worked out that wide too, and a variable has
            # only those bytes read; a shift down by whole bytes of a variable is its bytes higher
            # up. Anything else is worked out whole, which has the low bytes right as well.
            def low_value(operand, bytes)
              return value(operand) if bytes > 2 || folded(operand)

              name = variable_named(operand)
              return emit_low_bytes_at(place_of(name), bytes) if name
              return value(operand) unless operand.is_a?(Node) && operand.kind == :binop

              case operand.op
              when :+, :-, :&, :|, :^ then emit_low_sum(operand, bytes)
              when :>> then emit_low_bytes_shifted_down(operand, bytes)
              else value(operand)
              end
            end

            # E (and D) = the +bytes+ bytes kept from +address+ up.
            def emit_low_bytes_at(address, bytes)
              if bytes == 1
                @asm.load(:a, [address])
                return @asm.load(:e, :a)
              end

              @asm.load(:hl, address)
              @asm.load(:a, [:hli])
              @asm.load(:e, :a)
              @asm.load(:d, [:hl])
            end

            # A variable shifted down by whole bytes, its low bytes read from where they are kept,
            # higher up; anything else worked out whole.
            def emit_low_bytes_shifted_down(node, bytes)
              count = folded(node.rhs)
              name = variable_named(node.lhs)
              return value(node) unless name && count && (count % 8).zero? && count.between?(0, 31) && (count / 8) + bytes <= 4

              emit_low_bytes_at(place_of(name) + (count / 8), bytes)
            end

            # The SM83's add and subtract, and the instructions that go on with the carry; AND, OR
            # and XOR carry nothing, so each byte is the same instruction.
            LOW_SUMS = Ractor.make_shareable({ :+ => %i[add_a adc_a], :- => %i[sub_a sbc_a], :& => %i[and_a and_a],
                                               :| => %i[or_a or_a], :^ => %i[xor_a xor_a] })

            # The low +bytes+ bytes of a sum, an AND, an OR or an XOR of two sides each worked out
            # that wide. The right-hand side is worked out first and kept on the stack, as a sum of
            # four bytes keeps it, unless it is a number or a variable, which is read where it is.
            def emit_low_sum(node, bytes)
              first, carried = LOW_SUMS.fetch(node.op)
              left, right = node.lhs, node.rhs
              left, right = right, left if node.op != :- && folded(left)
              number = folded(right)
              name = variable_named(right)
              unless number || name
                low_value(right, bytes)
                @asm.push(:de)
              end
              low_value(left, bytes)
              if number
                %i[e d].first(bytes).each_with_index do |register, i|
                  @asm.load(:a, register)
                  @asm.public_send(i.zero? ? first : carried, (number >> (8 * i)) & 0xFF)
                  @asm.load(register, :a)
                end
                return
              end

              name ? @asm.load(:hl, place_of(name)) : @asm.pop(:hl)
              %i[e d].first(bytes).each_with_index do |register, i|
                @asm.load(:a, register)
                if name
                  @asm.inc(:hl) unless i.zero?
                  @asm.public_send(i.zero? ? first : carried, [:hl])
                else
                  @asm.public_send(i.zero? ? first : carried, i.zero? ? :l : :h)
                end
                @asm.load(register, :a)
              end
            end

            # --- comparisons with a number written in the program ---

            # An ordering (<, <=, >, >=) of a value against a number written in the program, either
            # side: [the value, the number it is asked to be below, and whether the ordering holds
            # when it is below (true) or when it is not], every ordering being one of those two.
            # One whose answer is the same whatever the value is gives [the value, nil, the
            # answer]. Nil for any other test.
            def ordering_with_number(condition)
              return nil unless condition.is_a?(Node) && condition.kind == :binop && %i[< <= > >=].include?(condition.op)

              op = condition.op
              other, number = condition.lhs, folded(condition.rhs)
              unless number
                number = folded(condition.lhs) or return nil
                other = condition.rhs
                op = { :< => :>, :<= => :>=, :> => :<, :>= => :<= }.fetch(op) # k < x is x > k
              end
              number = Int32.wrap(number)
              # x <= k is x < k + 1, and x > k is x not below k + 1, which every x is for the biggest k.
              return [other, number, op == :<] if %i[< >=].include?(op)
              return [other, nil, op == :<=] if number == Int32::MAX

              [other, number + 1, op == :<=]
            end

            # The carry set when +operand+'s number is below +number+, counted with their signs, and
            # clear when it is not: the subtraction of the two a byte at a time, as rt_cmp32 does,
            # with the top bytes' sign bits turned over so the negative numbers come below the rest.
            # A variable's bytes are read where it is kept. A clobbers HL.
            def emit_carry_when_below(operand, number)
              number &= 0xFFFF_FFFF
              bytes = Array.new(4) { |i| (number >> (8 * i)) & 0xFF }
              if (name = variable_named(operand))
                place = place_of(name)
                @asm.load(:a, [place + 3])
                @asm.xor_a(0x80)
                @asm.load(:b, :a)
                @asm.load(:hl, place)
                @asm.load(:a, [:hli])
                @asm.sub_a(bytes[0])
                @asm.load(:a, [:hli])
                @asm.sbc_a(bytes[1])
                @asm.load(:a, [:hl])
                @asm.sbc_a(bytes[2])
                @asm.load(:a, :b)
              else
                value(operand)
                @asm.load(:a, :b)
                @asm.xor_a(0x80)
                @asm.load(:h, :a) # a load moves no flag, so the carry from the byte below is kept
                @asm.load(:a, :e)
                @asm.sub_a(bytes[0])
                @asm.load(:a, :d)
                @asm.sbc_a(bytes[1])
                @asm.load(:a, :c)
                @asm.sbc_a(bytes[2])
                @asm.load(:a, :h)
              end
              @asm.sbc_a(bytes[3] ^ 0x80)
            end

            # Jump to +label+ unless +operand+'s number is below +number+ (or is not, when +below+ is false).
            def jump_unless_below(operand, number, below, label)
              emit_carry_when_below(operand, number)
              @asm.jump(below ? :nc : :c, label)
            end

            # BCDE = 1 when +operand+'s number is below +number+ (or is not, when +below+ is false),
            # and 0 when not. The loads move no flag, so the carry is asked after them.
            def emit_bool_of_below(operand, number, below)
              emit_carry_when_below(operand, number)
              done = fresh("bool")
              @asm.load(:bc, 0)
              @asm.load(:de, 0)
              @asm.jump_relative(below ? :nc : :c, done)
              @asm.inc(:e)
              @asm.label(done)
            end
          end
        end
      end
    end
  end
end
