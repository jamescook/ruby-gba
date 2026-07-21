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

    module_function

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

      raise Error, "expected #{expected} bytes of pixel data for a #{width}x#{height} " \
                   "image, but the adapter returned #{bytes.bytesize}"
    end

    # The adapter used when a caller doesn't name one. A single shared instance
    # is fine — it holds no per-image state, just the resolved tool.
    def default_adapter
      @default_adapter ||= Adapters::ImageMagick.new
    end
  end
end

require_relative "image/adapters/image_magick"
