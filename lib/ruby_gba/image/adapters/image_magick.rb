# frozen_string_literal: true

require "open3"

module RubyGBA
  module Image
    module Adapters
      # Turns an image file into raw pixels by driving ImageMagick, the image
      # tool most machines already have (or can install in one command).
      #
      # It asks ImageMagick to resize-and-crop the picture to the exact size you
      # asked for and hand back the raw red/green/blue bytes — one byte per
      # channel, three per pixel, left to right and top to bottom. That raw form
      # is all the library needs; turning it into the console's color format
      # happens elsewhere, so this adapter knows nothing about the GBA.
      class ImageMagick
        # ImageMagick 7 ships the `magick` command; older installs only have
        # `convert`. Try them in that order.
        BINARIES = %w[magick convert].freeze

        # @param binary [String, nil] force a specific command (mainly for tests);
        #   nil resolves one from PATH on first use.
        def initialize(binary: nil)
          @binary = binary
        end

        # Raw RGB888 for +path+ resized and cropped to width x height: a binary
        # string of width*height*3 bytes, row-major, top-left origin. Any
        # transparency is flattened onto white, for a clean opaque import.
        def rgb_pixels(path, width:, height:)
          extract(path, width, height, format: "RGB", background: "white")
        end

        # Raw RGBA8888 — the same pixels plus a fourth alpha byte each (0 fully
        # transparent, 255 fully opaque). Keeps transparency (background none) so
        # a cutout's removed background can be made see-through.
        def rgba_pixels(path, width:, height:)
          extract(path, width, height, format: "RGBA", background: "none")
        end

        # The resolved command, found once and remembered. If ImageMagick isn't
        # installed — the single most likely setup problem — say so in plain
        # language and name the install step, rather than leaking a raw
        # "command not found".
        def binary
          @binary ||= BINARIES.find { |name| available?(name) } || raise(unavailable_error)
        end

        private

        # Ask ImageMagick to resize-and-crop +path+ to width x height and dump the
        # raw pixels of the given +format+ ("RGB" -> 3 bytes/pixel, "RGBA" -> 4)
        # to stdout, compositing any transparency over +background+.
        #
        # -background BG   the color the crop composites over (see the callers:
        #                  white to flatten transparency, none to keep it),
        # -resize BOX^     scales the image to COVER the box (fill it, keeping the
        #                  aspect ratio, so nothing is squashed),
        # -gravity center -extent BOX  then crops the overflow to an exact
        #                  rectangle centered on the picture,
        # -depth 8 FORMAT:-  writes the raw 8-bit channels straight to stdout, no
        #                  file header — just the pixels.
        def extract(path, width, height, format:, background:)
          box = "#{width}x#{height}"
          args = [binary, path,
                  "-background", background,
                  "-resize", "#{box}^", "-gravity", "center", "-extent", box,
                  "-depth", "8", "#{format}:-"]
          out, err, status = Open3.capture3(*args, binmode: true)
          unless status.success?
            raise Error, "ImageMagick could not convert #{path.inspect}: #{err.strip}"
          end

          out
        end

        # Whether +name+ can actually run — the honest test is to invoke it.
        def available?(name)
          _out, _err, status = Open3.capture3(name, "-version")
          status.success?
        rescue Errno::ENOENT
          false
        end

        def unavailable_error
          BackendUnavailable.new(
            "ImageMagick isn't installed, so images can't be imported. Install it " \
            "and try again — on macOS run `brew install imagemagick`, on " \
            "Debian/Ubuntu run `sudo apt-get install imagemagick`.",
          )
        end
      end
    end
  end
end
