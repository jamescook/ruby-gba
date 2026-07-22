# frozen_string_literal: true

module RubyGBA
  class Builder
    # The image + color verbs: define a bitmap (from raw data, a file, or ASCII
    # art), draw it with blit, and build colors (rgb/rgb8/color). A concern of
    # {Builder}, mixed in so these stay flat DSL verbs.
    module Images
      # The unused 16th bit of a BGR555 color, set to mark a pixel transparent — a
      # real color is 0x0000..0x7FFF, so this can never collide with one.
      TRANSPARENT_PIXEL = 0x8000

      # Define a bitmap, two ways.
      #
      # Array form — raw pixel data, the shape the importer produces. +data+ is
      # width*height colors (names, hex strings, or raw BGR555 integers), row-major:
      #
      #   image :friend, width: 16, height: 16, data: bmp.data
      #
      # From-a-file form — hand it an image on your machine and a size, and it's
      # imported (via RubyGBA::Image) and embedded in one step:
      #
      #   image :friend, from: "friend.png", width: 16, height: 16
      #
      # Add transparent: true for a cut-out (an image with its background removed):
      # the removed areas become see-through, so the game field shows through them
      # instead of a rectangle.
      #
      #   image :friend, from: "cutout.png", width: 16, height: 16, transparent: true
      #
      # ASCII-art form — hand-drawn, with a char=>color map and a block of art. The
      # dimensions come from the art's shape, and one char may map to :transparent
      # (those pixels aren't drawn, so the background shows through):
      #
      #   image :ship, "." => :transparent, "#" => :cyan, "*" => :red do
      #     <<~ART
      #       ..#..
      #       .#*#.
      #       #####
      #     ART
      #   end
      #
      # Either way the pixels are packed to 15-bit color and embedded in the ROM; a
      # later `blit` draws it by name.
      # +opts+ is a single trailing hash — the char=>color map (ASCII form, with a
      # block), width:/height:/data: (array form), or from:/width:/height: (file
      # form). It's positional, not keywords, so the char map's string keys (like
      # "#") pass through cleanly.
      def image(name, opts = {}, &block)
        if block
          define_ascii_image(name, opts, &block)
        elsif opts[:from]
          bmp = Image.load(opts[:from], width: opts[:width], height: opts[:height],
                                        transparent: opts.fetch(:transparent, false))
          define_pixel_image(name, width: bmp.width, height: bmp.height, data: bmp.data,
                                   transparent: bmp.transparent)
        else
          define_pixel_image(name, width: opts[:width], height: opts[:height], data: opts[:data],
                                   transparent: opts[:transparent])
        end
      end

      # Draw a bitmap (defined with `image`) at a position, which may be a variable
      # (a moving object) or a constant. Keep it on-screen — off-screen parts aren't
      # clipped at run time yet.
      #
      # @example
      #   blit :friend, :ball_x, :ball_y
      def blit(name, x, y)
        record(Build.blit(name, Value.node_for(x), Value.node_for(y)))
        ensure_var(x)
        ensure_var(y)
      end

      # Pack 5-bit RGB channels (0-31 each) into a 15-bit GBA color.
      # Raises on out-of-range values to catch mistakes early.
      def rgb(r, g, b)
        Color.rgb(r, g, b)
      end

      # Pack 8-bit RGB channels (0-255 each) into a 15-bit GBA color.
      # Automatically downsamples to 5-bit per channel.
      def rgb8(r, g, b)
        Color.rgb8(r, g, b)
      end

      # Resolve a color from a name, hex string, or raw value.
      def color(value)
        Color.resolve(value)
      end

      private

      # Array form of #image: validate the dimensions and pack the pixel colors.
      # +transparent+ (an internal marker color, e.g. from an imported cutout) is
      # left untouched while every other pixel is resolved — otherwise resolving it
      # would mask the marker away — and it's recorded on the bitmap so `blit`
      # skips those pixels, letting the background show through.
      def define_pixel_image(name, width:, height:, data:, transparent: nil)
        positive_dims!(name, width, height)
        expected = width * height
        unless data.length == expected
          raise ArgumentError,
                "image :#{name} is #{width}x#{height}, so it needs #{expected} pixels, but got #{data.length}"
        end

        pixels = data.map { |c| c == transparent ? transparent : Color.resolve(c) }.pack("v*")
        record(Build.bitmap(name, width: width, height: height, pixels: pixels, transparent: transparent))
      end

      # ASCII-art form of #image: split the block's art into rows, infer the size
      # from its shape, map each char to a color (or transparency), and pack it.
      def define_ascii_image(name, char_map)
        rows = yield.to_s.each_line.map(&:chomp).reject(&:empty?)
        raise ArgumentError, "image :#{name} has no art" if rows.empty?

        widths = rows.map(&:length).uniq
        unless widths.size == 1
          raise ArgumentError,
                "image :#{name} has ragged rows (#{widths.sort.join(', ')} wide) — every row must be the same length"
        end

        transparent = false
        colors = rows.flat_map do |row|
          row.each_char.map do |ch|
            spec = char_map.fetch(ch) { raise ArgumentError, "image :#{name}: no color mapped for '#{ch}'" }
            if spec == :transparent
              transparent = true
              TRANSPARENT_PIXEL
            else
              Color.resolve(spec)
            end
          end
        end

        record(Build.bitmap(name, width: widths.first, height: rows.size,
                                  pixels: colors.pack("v*"),
                                  transparent: transparent ? TRANSPARENT_PIXEL : nil))
      end

      def positive_dims!(name, width, height)
        return if width.is_a?(Integer) && width.positive? && height.is_a?(Integer) && height.positive?

        raise ArgumentError, "image :#{name} needs positive width and height (got #{width}x#{height})"
      end
    end
  end
end
