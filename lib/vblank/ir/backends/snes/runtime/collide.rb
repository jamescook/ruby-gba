# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # DO TWO SPRITES' DRAWN PIXELS TOUCH? (`a.overlaps?(b)` without a `hitbox:`,
          # Reference#pixels_overlap?.) Each sprite is showing one of its pictures, picked by a
          # number, at a place; the two pictures' boxes may overlap, and where they do, each
          # pixel is asked whether both pictures draw it. The first one both draw answers yes.
          #
          # Each picture a sprite can show is kept for this as a MASK (Lowering::Collision): a bit
          # for each of its pixels, set where it draws, eight to a byte, leftmost pixel in the top
          # bit, a row at a time — the table "collision pictures" says where each is, its width and
          # its height. A sprite's pictures are a list, by number ("collision lists": how many,
          # then each picture's number).
          #
          #   rt_pixels_overlap(a_list, a_pose, a_x, a_y, b_list, b_pose, b_x, b_y)  R0 = 1 or 0
          #
          # A pose below nought counts back from the last picture, as the interpreter reads it; one
          # that names none of them stops the game (PICTURE_NOT_THERE). Two sprites more than 4096
          # pixels apart either way do not touch, so everything below works in 16 bits.
          module Collide
            R = Ractor.make_shareable(->(n) { Memory.register(n) })
            FAR = 4096

            # The direct page the routine works on: for each sprite, its picture's mask (three
            # bytes and a spare), its width, its height and its bytes a row; where the second sits
            # from the first; the box both cover, in the first's pixels; and the row and column
            # being asked.
            Sprite = Data.define(:mask, :width, :height, :row_bytes)
            Scratch = Data.define(:first, :second, :list, :pose, :across, :down, :left, :right, :top, :bottom,
                                  :x, :y, :row, :second_row)

            module_function

            def scratch(memory)
              sprite = -> { Sprite.new(mask: memory.scratch(4), width: memory.scratch(2), height: memory.scratch(2),
                                       row_bytes: memory.scratch(2)) }
              Scratch.new(first: sprite.call, second: sprite.call, list: memory.scratch(4), pose: memory.scratch(4),
                          across: memory.scratch(2), down: memory.scratch(2), left: memory.scratch(2),
                          right: memory.scratch(2), top: memory.scratch(2), bottom: memory.scratch(2),
                          x: memory.scratch(2), y: memory.scratch(2), row: memory.scratch(4),
                          second_row: memory.scratch(4))
            end

            def emit(asm, memory, s)
              asm.label("rt_pixels_overlap")
              # Each sprite's picture.
              [[s.first, R.call(0), R.call(1)], [s.second, R.call(4), R.call(5)]].each do |sprite, list, pose|
                asm.lda(asm.direct(list))
                asm.sta(asm.direct(s.list))
                asm.lda(asm.direct(pose))
                asm.sta(asm.direct(s.pose))
                asm.lda(asm.direct(pose + 2))
                asm.sta(asm.direct(s.pose + 2))
                asm.jsr(asm.abs("rt_collide_picture"))
                [[0, sprite.mask], [2, sprite.mask + 2], [4, sprite.width], [6, sprite.height]].each do |from, to|
                  asm.lda(asm.long_x("collision pictures", from))
                  asm.sta(asm.direct(to))
                end
                asm.lda(asm.direct(sprite.width))
                asm.clc
                asm.adc(7)
                3.times { asm.lsr }
                asm.sta(asm.direct(sprite.row_bytes))
              end
              # Where the second sits from the first: near enough, or no touch.
              [[R.call(6), R.call(2), s.across], [R.call(7), R.call(3), s.down]].each do |second, first, out|
                asm.lda(asm.direct(second))
                asm.sec
                asm.sbc(asm.direct(first))
                asm.sta(asm.direct(out))
                asm.lda(asm.direct(second + 2))
                asm.sbc(asm.direct(first + 2))
                asm.tax
                asm.lda(asm.direct(out))
                asm.clc
                asm.adc(FAR)
                asm.txa
                asm.adc(0)
                asm.branch_long(:bne, "rt_pixels_overlap_no")
                asm.lda(asm.direct(out))
                asm.clc
                asm.adc(FAR)
                asm.cmp(FAR * 2)
                asm.branch_long(:bcs, "rt_pixels_overlap_no")
              end
              # The box both cover, in the first's pixels: from the later left edge to the earlier
              # right one, and the same down.
              [[s.across, s.second.width, s.first.width, s.left, s.right],
               [s.down, s.second.height, s.first.height, s.top, s.bottom]].each do |at, second_size, first_size, from, to|
                asm.lda(asm.direct(at))
                asm.bpl("rt_pixels_overlap_#{from}_kept")
                asm.lda(0)
                asm.label("rt_pixels_overlap_#{from}_kept")
                asm.sta(asm.direct(from))
                asm.lda(asm.direct(at))
                asm.clc
                asm.adc(asm.direct(second_size))
                asm.cmp(asm.direct(first_size))
                asm.bmi("rt_pixels_overlap_#{to}_kept")
                asm.lda(asm.direct(first_size))
                asm.label("rt_pixels_overlap_#{to}_kept")
                asm.sta(asm.direct(to))
                asm.sec
                asm.sbc(asm.direct(from))
                asm.branch_long(:bmi, "rt_pixels_overlap_no")
                asm.branch_long(:beq, "rt_pixels_overlap_no")
              end
              # Each row of the box: where it starts in each mask.
              asm.lda(asm.direct(s.top))
              asm.sta(asm.direct(s.y))
              asm.label("rt_pixels_overlap_row")
              [[s.first, s.row, s.y, nil], [s.second, s.second_row, s.y, s.down]].each do |sprite, row, y, less|
                asm.lda(asm.direct(y))
                if less
                  asm.sec
                  asm.sbc(asm.direct(less))
                end
                asm.tax
                asm.lda(asm.direct(sprite.mask))
                asm.sta(asm.direct(row))
                asm.lda(asm.direct(sprite.mask + 2))
                asm.sta(asm.direct(row + 2))
                asm.label("rt_pixels_overlap_down_#{row}")
                asm.cpx(0)
                asm.beq("rt_pixels_overlap_at_#{row}")
                asm.lda(asm.direct(row))
                asm.clc
                asm.adc(asm.direct(sprite.row_bytes))
                asm.sta(asm.direct(row))
                asm.dex
                asm.bra("rt_pixels_overlap_down_#{row}")
                asm.label("rt_pixels_overlap_at_#{row}")
              end
              asm.lda(asm.direct(s.left))
              asm.sta(asm.direct(s.x))
              asm.label("rt_pixels_overlap_pixel")
              # The first's pixel, then the second's.
              [[s.row, s.x, nil], [s.second_row, s.x, s.across]].each do |row, x, less|
                asm.lda(asm.direct(x))
                if less
                  asm.sec
                  asm.sbc(asm.direct(less))
                end
                asm.pha
                3.times { asm.lsr }
                asm.tay
                asm.pla
                asm.and_a(7)
                asm.tax
                asm.lda(asm.ind_long_y(row))
                asm.and_a(asm.long_x("rt_collide_bits"))
                asm.and_a(0x00FF)
                asm.beq("rt_pixels_overlap_next")
              end
              asm.lda(1)
              asm.bra("rt_pixels_overlap_answer")
              asm.label("rt_pixels_overlap_next")
              asm.inc(asm.direct(s.x))
              asm.lda(asm.direct(s.x))
              asm.cmp(asm.direct(s.right))
              asm.bcc("rt_pixels_overlap_pixel")
              asm.inc(asm.direct(s.y))
              asm.lda(asm.direct(s.y))
              asm.cmp(asm.direct(s.bottom))
              asm.branch_long(:bcc, "rt_pixels_overlap_row")
              asm.label("rt_pixels_overlap_no")
              asm.lda(0)
              asm.label("rt_pixels_overlap_answer")
              asm.sta(asm.direct(R.call(0)))
              asm.stz(asm.direct(R.call(0) + 2))
              asm.rtl

              emit_picture(asm, memory, s)
              asm.label("rt_collide_bits")
              asm.data_bytes(0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01)
            end

            # rt_collide_picture (JSR): X = where in "collision pictures" the picture numbered +pose+
            # in the list numbered +list+ is, counting back from the last for a pose below nought; a
            # pose naming none of them stops the game.
            def emit_picture(asm, memory, s)
              asm.label("rt_collide_picture")
              asm.lda(asm.direct(s.list))
              asm.asl
              asm.asl
              asm.tax
              asm.lda(asm.long_x("collision lists"))
              asm.sta(asm.direct(s.row))
              asm.lda(asm.long_x("collision lists", 2))
              asm.sta(asm.direct(s.row + 2))
              asm.lda(asm.direct(s.pose + 2))
              asm.bpl("rt_collide_picture_counted")
              asm.lda(asm.direct(s.pose))
              asm.clc
              asm.adc(asm.ind_long(s.row))
              asm.tax
              asm.lda(asm.direct(s.pose + 2))
              asm.adc(0)
              asm.bne("rt_collide_picture_none")
              asm.txa
              asm.bra("rt_collide_picture_check")
              asm.label("rt_collide_picture_counted")
              asm.bne("rt_collide_picture_none")
              asm.lda(asm.direct(s.pose))
              asm.label("rt_collide_picture_check")
              asm.cmp(asm.ind_long(s.row))
              asm.bcs("rt_collide_picture_none")
              asm.inc
              asm.asl
              asm.tay
              asm.lda(asm.ind_long_y(s.row))
              3.times { asm.asl }
              asm.tax
              asm.rts
              asm.label("rt_collide_picture_none")
              # The pose and the count: the fault's two numbers, as the interpreter words it.
              fault = memory[Frame::FAULT]
              asm.lda(asm.direct(s.pose))
              asm.sta(asm.abs(fault + Frame::FAULT_FIRST))
              asm.lda(asm.direct(s.pose + 2))
              asm.sta(asm.abs(fault + Frame::FAULT_FIRST + 2))
              asm.lda(asm.ind_long(s.row))
              asm.sta(asm.abs(fault + Frame::FAULT_SECOND))
              asm.stz(asm.abs(fault + Frame::FAULT_SECOND + 2))
              asm.lda(Frame::PICTURE_NOT_THERE)
              asm.jml(asm.long("rt_fault"))
            end
          end
        end
      end
    end
  end
end
