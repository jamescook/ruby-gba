# frozen_string_literal: true

module RubyGBA
  module DSL
    # A PICTURE THE GAME DRAWS INTO WHILE IT RUNS, handed back by `canvas`.
    #
    # Underneath it is the list a `tiles ..., from: list` run or an `image ..., from: list`
    # picture paints from, and the canvas keeps that list for you: it fills it, packs each
    # pixel into the half of a byte the console wants, and says `changed` after every word,
    # so the picture shows on the next frame. What a game holds is the words — a pixel, a
    # rectangle, a picture stamped on, a letter, a line of text, a number — in colour names.
    #
    # Every word is built from what a game could write itself (list reads and writes, the bit
    # operators, a table, a loop, a routine), which is why it works the same on the console
    # and in the interpreter — and from one thing it could not: setting a run of the list's
    # bytes at once (IR list_fill), which `clear` and `fill_rect` use for whole bytes, where a
    # byte at a time cost a clear of a big canvas most of a frame.
    #
    # A POSITION THE GAME WORKS OUT IS CLIPPED at the canvas edge, so a dot that wandered off
    # needs no test around it. A position written as a number past the edge is a friendly
    # error, since that one could only be a mistake.
    class Canvas
      attr_reader :name, :width, :height

      def initialize(builder, name:, list:, run:, width:, height:, colors:)
        @builder = builder
        @name = name
        @list = list
        @run = run
        @width = width
        @height = height
        @colors = colors
        @x = builder.var(part(:x), 0)
        @y = builder.var(part(:y), 0)
        @place = builder.var(part(:place), 0)
        @pixel_routine = nil
      end

      # The list the pixels live in, packed the way the console keeps them, for a game that
      # wants to write bytes itself. Say `changed` after.
      def list = @list

      # Show what the list holds on the next frame. Every drawing word says it already.
      def changed = @run.changed

      # The cells of a background map that show this canvas, as rows of tile keys — the
      # first row of the canvas's tiles, then the next. Put them in a map as they are, or
      # beside other tiles of the same tileset. (A canvas a sprite shows has none.)
      def cells
        across = @width / 8
        (0...(@height / 8)).map { |row| (1..across).map { |col| (row * across) + col } }
      end

      # One pixel. +x+ and +y+ may be worked out as the game runs.
      def pixel(x, y, color)
        refuse_written_position_outside!(x, y)
        paint_at(x, y, place_of(color))
        changed
        nil
      end

      # The whole canvas one colour; see-through when no colour is given. Every byte of the
      # list holds two pixels of that colour, so it is one run of the list filled at once.
      def clear(color = :transparent)
        place = place_of(color)
        fill_bytes(0, @width * @height / 2, place | (place << 4))
        changed
        nil
      end

      # A filled rectangle, any width. Every part of it may be worked out as the game runs; a
      # width or height of 0 or less draws nothing, and what falls outside the canvas is cut
      # off.
      #
      # A ROW OF IT IS WHOLE BYTES with at most a pixel left over at each end, since a byte
      # holds two pixels side by side, left one first. So each row paints its odd end pixels
      # one at a time and fills the bytes between — a run per tile it crosses, because a row
      # of one tile is four bytes and the same row of the next tile is a whole tile further on
      # in the list.
      def fill_rect(x, y, w, h, color)
        refuse_written_position_outside!(x, y)
        place = place_of(color)
        left = scratch(:left)
        right = scratch(:right)
        row_y = scratch(:row_y)
        left.set! value(x).clamp(0, @width)
        right.set! plus(x, w).clamp(0, @width)
        @place.set! place
        @builder.repeat(h) do |row|
          row_y.set! plus(y, row)
          ((row_y >= 0) & (row_y < @height) & (left < right)).then { @builder.call(fill_row_routine) }
        end
        changed
        nil
      end

      # A picture declared with `image`, stamped on with its top-left at +x+, +y+. Its
      # see-through pixels leave the canvas as it was. Every colour it draws must be one of
      # the canvas's own.
      def blit(image, x, y)
        refuse_written_position_outside!(x, y)
        table = picture_table(image)
        across = @builder.image_size(image).first
        @builder.repeat(table.length) do |i|
          place = table[i]
          (place != 0).then { paint_at(plus(x, i % across), plus(y, i / across), place) }
        end
        changed
        nil
      end

      # One letter of +font+ with its top-left at +x+, +y+. +code+ is the character, or its
      # number — which may be worked out as the game runs, so a name kept in a list can be
      # drawn a letter at a time. Hands back how far across the letter reached, gap included,
      # as a Value: where the next letter goes.
      def draw_letter(code, x, y, color, font: :default)
        refuse_written_position_outside!(x, y)
        code = code.ord if code.is_a?(String)
        tables = @builder.canvas_font_tables(font)
        place = place_of(color)
        rows = tables.rows
        widths = tables.widths
        tall = tables.height
        @builder.repeat(tall) do |row|
          bits = rows[(code * tall) + row]
          wide = widths[code]
          @builder.repeat(tables.widest) do |col|
            lit = ((bits >> (wide - 1 - col)) & 1) == 1
            ((col < wide) & lit).then { paint_at(plus(x, col), plus(y, row), place) }
          end
        end
        changed
        # Kept in a variable rather than handed back as a sum, so a game that draws a letter
        # and has no use for where it ended is not told it worked out a number for nothing.
        @advance ||= @builder.var(part(:advance), 0)
        @advance.set! widths[code] + tables.spacing
        @advance
      end

      # A line of text written in the program, with its top-left at +x+, +y+.
      def draw_text(text, x, y, color, font: :default)
        face = @builder.canvas_font(font)
        along = 0
        text.each_char do |char|
          draw_letter(char.ord, plus(x, along), y, color, font: font) if face.glyph(char)
          along += (face.glyph_width(char) || face.width) + face.spacing
        end
        nil
      end

      # A number the game works out, right-aligned in a field +digits+ wide, with no leading
      # zeros — the same field a `draw_number` draws.
      def draw_number(number, x, y, color, digits:, font: :default)
        cell = @builder.canvas_font(font).cell_w
        digits.times do |from_right|
          power = 10**from_right
          digit = (value(number) / power) % 10
          at = plus(x, (digits - 1 - from_right) * cell)
          shown = from_right.zero? ? nil : (value(number) >= power)
          draw = -> { draw_letter(digit + 48, at, y, color, font: font) }
          shown ? shown.then(&draw) : draw.call
        end
        nil
      end

      private

      def part(what) = Messages::MadeNames.make(:canvas_part, canvas: @name, part: what)

      # A variable of the canvas's own for a word's working, made the first time it is asked for.
      def scratch(what)
        @scratch ||= {}
        @scratch[what] ||= @builder.var(part(what), 0)
      end

      # +count+ bytes of the list from +from+ set to +byte+, in one statement.
      def fill_bytes(from, count, byte)
        @builder.record_statement(IR::Build.list_fill(@list.name, from: Value.node_for(from),
                                                                   count: Value.node_for(count),
                                                                   value: Value.node_for(byte)))
      end

      # The routine that fills one row of a rectangle, written once for the canvas however many
      # rectangles the game fills: the row in :row_y, from column :left up to but not including
      # :right, both inside the canvas, in the colour in :place.
      def fill_row_routine
        @fill_row_routine ||= begin
          name = part(:fill_row)
          row_y = scratch(:row_y)
          left = scratch(:left)
          right = scratch(:right)
          place = @place
          canvas = self
          @builder.func(name) { canvas.send(:fill_row, row_y, left, right, place) }
          name
        end
      end

      # One row of a rectangle at +row_y+, from column +left+ up to but not including +right+:
      # the odd end pixels one at a time, the whole bytes between a run per tile.
      def fill_row(row_y, left, right, place)
        from = scratch(:from_x)
        upto = scratch(:upto_x)
        tile = scratch(:tile)
        from.set! left
        upto.set! right
        ((from & 1) == 1).then do
          paint_at(from, row_y, place)
          from.add! 1
        end
        ((upto & 1) == 1).then do
          paint_at(upto - 1, row_y, place)
          upto.sub! 1
        end
        (from < upto).then do
          tile.set! from >> 3
          tiles = ((upto - 1) >> 3) - tile + 1
          @builder.repeat(tiles, estimate: { usually: 2, most: (@width / 8) + 1 }) do
            fill_row_in_tile(row_y, tile, from, upto, place)
            tile.add! 1
          end
        end
      end

      # The part of a row between +from+ and +upto+ that falls in tile column +tile+.
      def fill_row_in_tile(row_y, tile, from, upto, place)
        start = (tile << 3).clamp(from, upto)
        stop = ((tile << 3) + 8).clamp(from, upto)
        byte = ((((row_y >> 3) * (@width / 8)) + tile) * 32) + ((row_y & 7) * 4) + ((start & 7) >> 1)
        fill_bytes(byte, (stop - start) >> 1, place | (place << 4))
      end

      # +a+ plus +b+, kept a plain number when both are.
      def plus(a, b) = a.is_a?(Integer) && b.is_a?(Integer) ? a + b : value(a) + b

      # A number or a handle, as a handle the operators work on.
      def value(operand) = operand.is_a?(Value) ? operand : Value.new(@builder, Value.node_for(operand))

      # Paint one pixel through the canvas's own routine: three variables set and a call,
      # where the arithmetic would otherwise be written out again at every place it is used.
      def paint_at(x, y, place)
        @x.set! x
        @y.set! y
        @place.set! place
        @builder.call(pixel_routine)
      end

      # The routine that writes one pixel into the list: which tile it is in, which byte of
      # that tile, and which half of the byte. A tile is 8 rows of 4 bytes, and the left pixel
      # of each pair is the low half.
      def pixel_routine
        @pixel_routine ||= begin
          name = part(:pixel)
          x = @x
          y = @y
          place = @place
          list = @list
          across = @width / 8
          wide = @width
          tall = @height
          at = @builder.var(part(:at), 0)
          @builder.func(name) do
            ((x >= 0) & (x < wide) & (y >= 0) & (y < tall)).then do
              at.set! ((((y >> 3) * across) + (x >> 3)) * 32) + ((y & 7) * 4) + ((x & 7) >> 1)
              ((x & 1) == 0).then { list[at] = (list[at] & 0xF0) | place }
                            .else { list[at] = (list[at] & 0x0F) | (place << 4) }
            end
          end
          name
        end
      end

      # A picture's pixels as places in this canvas's colours, a table read as the stamp
      # runs. Built once per picture.
      def picture_table(image)
        name = Messages::MadeNames.make(:canvas_part, canvas: @name, part: "image_#{image}")
        pixels = @builder.image_pixels(image)
        places = pixels.map do |color|
          next 0 if color.nil?

          @colors.index(color) || raise(ArgumentError,
                                        "canvas :#{@name} stamps image :#{image}, which draws a colour the canvas " \
                                        "does not have (#{Graphics::Color.name_for(color)}). To fix this, add it to the " \
                                        "canvas's colors:.")
        end
        @tables ||= {}
        @tables[image] ||= @builder.table(name, places, width: :byte, signed: false)
      end

      def place_of(color)
        return 0 if color == :transparent

        resolved = Graphics::Color.resolve(color)
        at = @colors.each_index.find { |i| i.positive? && @colors[i] == resolved }
        at || raise(ArgumentError, "canvas :#{@name} draws in #{color.inspect}, which is not one of its colours. " \
                                   "To fix this, add it to the canvas's colors:.")
      end

      def refuse_written_position_outside!(x, y)
        return unless (x.is_a?(Integer) && !x.between?(0, @width - 1)) ||
                      (y.is_a?(Integer) && !y.between?(0, @height - 1))

        raise ArgumentError, "canvas :#{@name} is #{@width}x#{@height}, and a word draws at (#{x}, #{y}), which is " \
                             "outside it. A position the game works out is clipped at the edge, but one written " \
                             "as a number outside can only be a mistake. To fix this, give a position inside it."
      end
    end
  end
end
