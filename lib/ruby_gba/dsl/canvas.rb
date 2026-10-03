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
    # and in the interpreter with nothing new in either.
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

      # The whole canvas one colour; see-through when no colour is given.
      def clear(color = :transparent)
        place = place_of(color)
        both = place | (place << 4)
        list = @list
        @builder.repeat(@width * @height / 2) { |i| list[i] = both }
        changed
        nil
      end

      # A filled rectangle, any width. Every part of it may be worked out as the game runs; a
      # width or height of 0 or less draws nothing.
      def fill_rect(x, y, w, h, color)
        refuse_written_position_outside!(x, y)
        place = place_of(color)
        @builder.repeat(h) do |row|
          @builder.repeat(w) { |col| paint_at(plus(x, col), plus(y, row), place) }
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
