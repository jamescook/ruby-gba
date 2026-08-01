# frozen_string_literal: true

module RubyGBA
  # Bring a photo or drawing (PNG, JPG, …) into a game as ready-to-use pixels.
  #
  # You give it a filename and the size you want it on screen; you get back a
  # small object whose #data is a flat list of colors, ready to hand to `image`
  # (which embeds it in the ROM) and draw with `blit`:
  #
  #   bmp = RubyGBA::Image.load("friend.png", width: 16, height: 16)
  #   # ...inside a build block:
  #   image :friend, width: bmp.width, height: bmp.height, data: bmp.data
  #
  # or let the `image` verb fold both steps together with `from:`:
  #
  #   image :friend, from: "friend.png", width: 16, height: 16
  #
  # Nothing here mentions how the console stores color — that conversion happens
  # for you. The real image tool (ImageMagick today) sits behind a swappable
  # adapter, so the rest of the framework never shells out to it directly and a
  # different tool could drop in later without changing anything you write.
  module Image
    # Something went wrong importing an image.
    class Error < StandardError; end

    # The image tool (ImageMagick) isn't installed. Its message names the install.
    class BackendUnavailable < Error; end

    # The marker color that means "transparent" — the unused 16th bit of a color,
    # so it can never collide with a real one. A pixel set to this is skipped when
    # drawn, letting the background show through. This is the same marker the
    # engine's drawing uses.
    TRANSPARENT = 0x8000

    # How opaque a pixel must be to be drawn: alpha at or above this (0–255) keeps
    # its color, below it becomes transparent. A sensible middle so anti-aliased
    # cutout edges fall to whichever side they're closer to.
    DEFAULT_ALPHA_THRESHOLD = 128

    # A converted image: its on-screen size, its pixels, and (if it has
    # transparency) the marker color used for see-through pixels. #data is a flat,
    # row-major list of colors, one per pixel — exactly what `image`'s array form
    # wants. It's plain data and knows nothing about ROMs or hardware.
    Bitmap = Struct.new(:width, :height, :data, :transparent)

    # A single picture holding a grid of equal-size cells — a tile sheet or a
    # sprite sheet. It keeps the whole picture's pixels once, and hands back any
    # one cell (by column and row, top-left origin) as a ready-to-use {Bitmap}, so
    # a sheet of many tiles is decoded a single time rather than once per tile.
    class Sheet
      # How many cells across (+cols+) and down (+rows+) the sheet divides into.
      attr_reader :cols, :rows, :tile_w, :tile_h

      # @param pixels [String] the whole sheet's raw channel bytes, row-major
      # @param stride [Integer] the sheet's full pixel width (bytes per row = stride*per)
      # @param per [Integer] bytes per pixel in +pixels+ (3 for RGB, 4 for RGBA)
      # @param transparent [Boolean] whether cells honor an alpha cutout
      def initialize(pixels:, stride:, tile_w:, tile_h:, cols:, rows:, per:, transparent:, alpha_threshold:)
        @pixels = pixels
        @stride = stride
        @tile_w = tile_w
        @tile_h = tile_h
        @cols = cols
        @rows = rows
        @per = per
        @transparent = transparent
        @alpha_threshold = alpha_threshold
      end

      # The cell at column +col+, row +row+ (both zero-based, left-to-right then
      # top-to-bottom) as a {Bitmap} of the sheet's tile size. Raises with a
      # plain-language error if that cell is outside the grid.
      def cell(col, row)
        unless col.between?(0, @cols - 1) && row.between?(0, @rows - 1)
          raise Error, "Cell [#{col}, #{row}] is outside this #{@cols}x#{@rows}-cell sheet. " \
                       "Columns and rows start at 0. Use a column and row inside the grid."
        end

        ox = col * @tile_w
        oy = row * @tile_h
        data = Array.new(@tile_w * @tile_h) do |i|
          base = (((oy + (i / @tile_w)) * @stride) + ox + (i % @tile_w)) * @per
          pixel_color(base)
        end
        Bitmap.new(@tile_w, @tile_h, data, @transparent ? TRANSPARENT : nil)
      end

      private

      # One pixel's console color at byte offset +base+: for an opaque sheet just
      # its RGB folded down; for a transparent one, the see-through marker where the
      # pixel is more transparent than the cutoff, otherwise its color.
      def pixel_color(base)
        r = @pixels.getbyte(base)
        g = @pixels.getbyte(base + 1)
        b = @pixels.getbyte(base + 2)
        return Color.rgb8(r, g, b) unless @transparent
        return TRANSPARENT if @pixels.getbyte(base + 3) < @alpha_threshold

        Color.rgb8(r, g, b)
      end
    end

    module_function

    # Slice a sheet image into a grid of equal-size cells. Reads the picture at its
    # own resolution (no resizing, so tiles come across pixel-exact) and returns a
    # {Sheet} you pull individual cells from. Used by the `sheet` DSL verb to pull
    # named tiles / animation frames out of one PNG.
    #
    # @param path [String] a sheet image on the host machine (PNG, …)
    # @param tile_w [Integer] each cell's width in pixels
    # @param tile_h [Integer] each cell's height in pixels
    # @param transparent [Boolean] honor the sheet's transparency (for sprite cells
    #   whose background is cut out), turning see-through pixels into the marker.
    # @param alpha_threshold [Integer] the opacity cutoff (0–255) when +transparent+.
    # @param adapter the image tool; defaults to ImageMagick (a seam for tests).
    # @return [Sheet]
    def slice(path, tile_w:, tile_h:, transparent: false, alpha_threshold: DEFAULT_ALPHA_THRESHOLD,
              adapter: default_adapter)
      native_w, native_h = adapter.dimensions(path)
      divides_evenly!(path, native_w, native_h, tile_w, tile_h)

      per = transparent ? 4 : 3
      pixels = if transparent
                 adapter.rgba_pixels(path, width: native_w, height: native_h)
               else
                 adapter.rgb_pixels(path, width: native_w, height: native_h)
               end
      verify_size!(pixels, native_w, native_h, per)

      Sheet.new(pixels: pixels, stride: native_w, tile_w: tile_w, tile_h: tile_h,
                cols: native_w / tile_w, rows: native_h / tile_h,
                per: per, transparent: transparent, alpha_threshold: alpha_threshold)
    end

    # A sheet must split into whole tiles — a size that doesn't divide evenly means
    # the tile size (or the picture) is wrong, and slicing anyway would shear every
    # tile after the first, so we stop with a clear explanation instead.
    def divides_evenly!(path, native_w, native_h, tile_w, tile_h)
      raise Error, "The sheet tile size is #{tile_w}x#{tile_h}. The width and height must both be more than 0." unless tile_w.positive? && tile_h.positive?
      return if (native_w % tile_w).zero? && (native_h % tile_h).zero?

      raise Error,
            "The sheet #{path.inspect} is #{native_w}x#{native_h}. This size does not divide evenly into " \
            "#{tile_w}x#{tile_h} tiles (#{native_w}/#{tile_w} across, #{native_h}/#{tile_h} down). " \
            "Change the tile size or the picture so the size divides evenly."
    end

    # Load an image file and convert it to +width+ x +height+ pixels.
    #
    # @param path [String] an image file on the host machine (PNG, JPG, …)
    # @param width [Integer] on-screen width in pixels
    # @param height [Integer] on-screen height in pixels
    # @param transparent [Boolean] honor the image's transparency: pixels the
    #   image marks see-through (a removed/cut-out background) become the
    #   transparent marker, so the game field shows through instead of a box.
    #   Off by default — a plain photo imports fully opaque.
    # @param alpha_threshold [Integer] the opacity cutoff (0–255) when
    #   +transparent+ is on.
    # @param adapter the image tool to use; defaults to ImageMagick. Mainly a
    #   seam so tests can inject a canned adapter and run without the tool.
    # @return [Bitmap]
    def load(path, width:, height:, transparent: false, alpha_threshold: DEFAULT_ALPHA_THRESHOLD,
             adapter: default_adapter)
      return load_transparent(path, width, height, alpha_threshold, adapter) if transparent

      rgb = adapter.rgb_pixels(path, width: width, height: height)
      verify_size!(rgb, width, height, 3)

      # Each pixel is three bytes (red, green, blue, 0–255). Fold them into the
      # console's color through Color.rgb8 — the one place the whole codebase
      # downsamples 8-bit color, so imported images match hand-written ones.
      data = Array.new(width * height) do |i|
        Color.rgb8(rgb.getbyte(i * 3), rgb.getbyte(i * 3 + 1), rgb.getbyte(i * 3 + 2))
      end

      Bitmap.new(width, height, data, nil)
    end

    # The see-through variant: read RGBA, and turn each pixel's alpha into either
    # its color (opaque enough) or the transparent marker (too see-through).
    def load_transparent(path, width, height, alpha_threshold, adapter)
      rgba = adapter.rgba_pixels(path, width: width, height: height)
      verify_size!(rgba, width, height, 4)

      data = Array.new(width * height) do |i|
        alpha = rgba.getbyte(i * 4 + 3)
        if alpha < alpha_threshold
          TRANSPARENT # the background was removed here — let it show through
        else
          Color.rgb8(rgba.getbyte(i * 4), rgba.getbyte(i * 4 + 1), rgba.getbyte(i * 4 + 2))
        end
      end

      Bitmap.new(width, height, data, TRANSPARENT)
    end

    # Guard against an adapter that returned the wrong amount of data — a size
    # mismatch here would otherwise surface much later as garbled pixels.
    def verify_size!(bytes, width, height, per_pixel)
      expected = width * height * per_pixel
      return if bytes.bytesize == expected

      raise Error, "The #{width}x#{height} image needs #{expected} bytes of pixel data. " \
                   "The adapter returned #{bytes.bytesize} bytes."
    end

    # The adapter used when a caller doesn't name one. A single shared instance
    # is fine — it holds no per-image state, just the resolved tool.
    def default_adapter
      @default_adapter ||= Adapters::ImageMagick.new
    end
  end
end

require_relative "image/adapters/image_magick"
