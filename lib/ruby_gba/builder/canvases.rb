# frozen_string_literal: true

module RubyGBA
  class Builder
    # A CANVAS: a picture the game draws into with words while it runs (see DSL::Canvas).
    #
    # It is the friendly side of `tiles ..., from: list` and `image ..., from: list`. Those
    # hand the game a list to pack pixels into itself; this keeps the list and gives the game
    # words — a pixel, a rectangle, a picture, a letter, text, a number — in colour names.
    module Canvases
      # The characters a canvas can draw a letter of: every code a game writes as text.
      LETTER_CODES = 128

      # FontTables: one font, as the tables a canvas reads a letter out of while the game
      # runs — each character's rows of lit pixels, and its width.
      FontTables = Data.define(:rows, :widths, :height, :widest, :spacing)

      # Declare a canvas +width+ by +height+ pixels (each a whole number of tiles), drawn
      # from +colors+ (a `colors` list by name, or the colours themselves, see-through
      # first). By default a background shows it — `background :box, tiles: :name, map:
      # canvas.cells` — and other keys given here are ordinary tiles beside it in the same
      # tileset, a box's frame say. `as: :sprite` makes it a sprite's picture instead, and
      # then it is a size the console draws a sprite at.
      #
      # @return [DSL::Canvas]
      def canvas(name, width:, height:, colors:, as: :tiles, fast: nil, **fixed)
        refuse_bad_canvas!(name, width, height, as)
        bytes = width * height / 2
        list_name = Messages::MadeNames.make(:canvas_part, canvas: name, part: :pixels)
        filling = Messages::MadeNames.make(:canvas_part, canvas: name, part: :fill)
        # Made full at power-on, so every byte is there to write by number from the start.
        at_boot(Build.list_new(list_name, bytes, width: :byte, fast: fast))
        ensure_var(filling)
        at_boot(Build.repeat(bytes, filling, Build.list_push(list_name, Build.int(0))))
        list = DSL::List.new(self, list_name)
        run = if as == :sprite
                image(name, from: list, width: width, height: height, colors: colors)
              else
                tiles(name, { from: list, count: (width / 8) * (height / 8), colors: colors }.merge(fixed))
              end
        DSL::Canvas.new(self, name: name, list: list, run: run, width: width, height: height,
                              colors: tile_run_colors(name, colors, what: "canvas"))
      end

      # A font a canvas draws letters of, as tables read while the game runs. Made once per
      # font however many canvases use it.
      def canvas_font_tables(font)
        @canvas_font_tables ||= {}
        @canvas_font_tables[font] ||= begin
          face = canvas_font(font)
          rows = (0...LETTER_CODES).flat_map do |code|
            glyph = face.glyph(code.chr)
            Array.new(face.height) { |row| glyph ? glyph[row] : 0 }
          end
          widths = (0...LETTER_CODES).map { |code| face.glyph(code.chr) ? face.glyph_width(code.chr) : 0 }
          FontTables.new(
            rows: table(Messages::MadeNames.make(:canvas_font, font: font, part: :rows), rows, width: :half, signed: false),
            widths: table(Messages::MadeNames.make(:canvas_font, font: font, part: :widths), widths, width: :byte,
                                                                                                     signed: false),
            height: face.height, widest: face.width, spacing: face.spacing
          )
        end
      end

      # The font named +font+.
      def canvas_font(font) = IR::FontTable.of(@program).get(font)

      # A declared picture's size, [width, height].
      def image_size(image)
        @images.fetch(image) do
          raise ArgumentError, "there is no image named :#{image}. Define it first with `image :#{image}, ...`."
        end
      end

      # A declared picture's pixels, row by row: each one's colour, or nil where it is see-through.
      def image_pixels(image)
        image_size(image)
        node = @program.walk.find { |each| each.kind == :bitmap && each.name == image }
        picture = IR::Assets::Image.of(node)
        (0...(picture.width * picture.height)).map { |i| picture.drawn_at?(i) ? picture.color_at(i) : nil }
      end

      private

      def refuse_bad_canvas!(name, width, height, as)
        unless %i[tiles sprite].include?(as)
          raise ArgumentError, "canvas :#{name} was given `as: #{as.inspect}`. It is :tiles (the default, a " \
                               "background shows it) or :sprite."
        end
        return if [width, height].all? { |side| side.is_a?(Integer) && side.positive? && (side % 8).zero? }

        raise ArgumentError, "canvas :#{name} is #{width.inspect}x#{height.inspect}. Each side must be a whole " \
                             "number of tiles, so a multiple of 8. To fix this, round each side up to a multiple of 8."
      end
    end
  end
end
