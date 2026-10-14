# frozen_string_literal: true

require_relative "turned_box"

module RubyGBA
  module IR
    module Backends
      class Reference
        # A SPRITE SHOWN IN FLAT BLOCKS, the way a display that draws sprites as separate
        # objects shows one.
        #
        # THE BLOCKS ARE FIXED TO THE SCREEN, as a background's are: a block starts at every
        # column and every row that is a multiple of its size. What differs is where a
        # block takes its colour from, because a sprite is a small box and a block need not
        # start inside it. The rule below is the emulator's own, read out of its renderer
        # and measured on it, and it has edges a person would not guess:
        #
        #   * A block that starts to the LEFT of the box, or ABOVE it, shows the box's own
        #     first column or row. The place it reads is held inside the box.
        #   * The box's last block ACROSS is drawn whole, so the sprite runs on past its own
        #     right edge to the end of that block.
        #   * DOWN, nothing is drawn past the box's bottom edge.
        #
        # IT IS DONE TO EACH OBJECT, NOT TO EACH SPRITE. A display draws a sprite as one or
        # more boxes of the sizes it has — a pose trimmed to what it draws, a big picture
        # cut into pieces — and each box is put into blocks by itself, holding the place it
        # reads inside ITSELF. So which boxes a picture is drawn as is part of the answer,
        # and the caller hands them over (see SpriteCut).
        #
        # +size+ is how many pixels a block is each way. +screen+ is painted through
        # #set_pixel, so it clips and blends as it does for anything else.
        class SpriteBlocks
          def initialize(screen, size)
            @screen = screen
            @size = size
          end

          # A sprite that stands upright, its canvas's corner at (x, y). +boxes+ are the
          # parts of the canvas it is drawn as, each [left, top, width, height] inside the
          # canvas, the one in front first. The block answers the colour the canvas shows
          # at a column and row of it, or nil where it shows nothing.
          #
          # Painted back to front, so where one box's last block runs over the next box,
          # the one in front wins — and a see-through pixel of it leaves the other showing.
          def paint_upright(x, y, boxes)
            boxes.reverse_each do |left, top, width, height|
              paint_box(x + left, y + top, width, height) { |px, py| yield(px - x, py - y) }
            end
          end

          # A sprite that turns or resizes, drawn in a box twice its picture's size with the
          # picture's middle at the box's middle. The block answers the colour the turned
          # picture shows at a column and row of that box, or nil — and it is asked about
          # one column to the LEFT of the box as well, which is where the rule for a turned
          # sprite parts from an upright one's:
          #
          #   * A block that starts to the left of the box shows what the turned picture
          #     would show ONE COLUMN before the box begins, where an upright sprite shows
          #     its first column. That is nearly always nothing, so a turned sprite's first
          #     part block is usually empty.
          #   * A block that starts above the box shows the box's first row, and the last
          #     block across is drawn whole, both as an upright sprite's are (but see
          #     #turned_row for the one box that reads another row).
          #
          # +rows+ are the rows of the screen the box shows on, which the caller works out:
          # they are not always the rows it stands at (see TurnedBox).
          def paint_turned(left, top, width, height, rows)
            rows.each do |py|
              row = turned_row(py, top, height)
              ([left, 0].max...[round_up(left + width), @screen.width].min).each do |px|
                start = block_start(px)
                color = yield((start >= left ? start : left - 1) - left, row)
                @screen.set_pixel(px, py, color) if color
              end
            end
          end

          private

          # The row of its box a turned sprite shows on screen row +py+: the row at the top
          # of the block, held to the box's first row when the block began above it.
          #
          # Worked out the way the display counts, in lines that come round, because that
          # is where one case comes from that nobody would guess. A box so tall, and so
          # far down, that it ends past the last line the display counts — the box of a
          # sprite 64 pixels tall, turned, which is 128 — reads its LAST row on every row
          # that shows. It is the same for such a box hanging off the top of the screen
          # by most of its height.
          def turned_row(py, top, height)
            first = top % TurnedBox::LINES
            past = first + height
            line = block_start(py)
            line = first if line < first && first < @screen.height
            line = past - 1 if line >= past % TurnedBox::LINES
            (line - first) % TurnedBox::LINES
          end

          def paint_box(left, top, width, height)
            rows_on_screen(top, height).each do |py|
              from_y = block_start(py).clamp(top, top + height - 1)
              ([left, 0].max...[round_up(left + width), @screen.width].min).each do |px|
                color = yield(block_start(px).clamp(left, left + width - 1), from_y)
                @screen.set_pixel(px, py, color) if color
              end
            end
          end

          def rows_on_screen(top, height) = ([top, 0].max...[top + height, @screen.height].min)

          def block_start(at) = at - (at % @size)

          # The end of the block +edge+ falls in: the next multiple of the size at or past it.
          def round_up(edge) = -(-edge / @size) * @size
        end
      end
    end
  end
end
