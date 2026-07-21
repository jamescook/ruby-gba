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

    # A converted image: its on-screen size and its pixels. #data is a flat,
    # row-major list of colors, one per pixel — exactly what `image`'s array form
    # wants. It's plain data and knows nothing about ROMs or hardware.
    Bitmap = Struct.new(:width, :height, :data)

    module_function

    # Load an image file and convert it to +width+ x +height+ pixels.
    #
    # @param path [String] an image file on the host machine (PNG, JPG, …)
    # @param width [Integer] on-screen width in pixels
    # @param height [Integer] on-screen height in pixels
    # @param adapter the image tool to use; defaults to ImageMagick. Mainly a
    #   seam so tests can inject a canned adapter and run without the tool.
    # @return [Bitmap]
    def load(path, width:, height:, adapter: default_adapter)
      rgb = adapter.rgb_pixels(path, width: width, height: height)

      expected = width * height * 3
      unless rgb.bytesize == expected
        raise Error, "expected #{expected} bytes of pixel data for a #{width}x#{height} " \
                     "image, but the adapter returned #{rgb.bytesize}"
      end

      # Each pixel is three bytes (red, green, blue, 0–255). Fold them into the
      # console's color through Color.rgb8 — the one place the whole codebase
      # downsamples 8-bit color, so imported images match hand-written ones.
      data = Array.new(width * height) do |i|
        Color.rgb8(rgb.getbyte(i * 3), rgb.getbyte(i * 3 + 1), rgb.getbyte(i * 3 + 2))
      end

      Bitmap.new(width, height, data)
    end

    # The adapter used when a caller doesn't name one. A single shared instance
    # is fine — it holds no per-image state, just the resolved tool.
    def default_adapter
      @default_adapter ||= Adapters::ImageMagick.new
    end
  end
end

require_relative "image/adapters/image_magick"
