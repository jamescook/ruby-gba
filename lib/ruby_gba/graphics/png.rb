# frozen_string_literal: true

require "zlib"

module RubyGBA
  module Graphics
    # A PICTURE WRITTEN AS A PNG FILE: a screen, or any block of the console's colours, in the
    # one image format every viewer and browser opens.
    #
    # The rest of this module reads art IN, from whatever shape another tool left it in. This
    # is the way out — a picture of what a game showed, for a person to look at.
    #
    #   RubyGBA::Graphics::PNG.write("title.png", width: 240, height: 160, pixels: colours)
    #
    # WHAT A PNG IS, since this writes one byte by byte. After an eight-byte signature it is a
    # run of chunks, each its length, a four-letter type, its data and a check over the two.
    # Three are enough: a header saying the size and how a pixel is stored, the pixels
    # themselves squeezed with the same compression a zip file uses, and an empty one to end.
    #
    # HOW A COLOUR GETS THERE. The console keeps a colour in 15 bits, five each for red, green
    # and blue, so a channel has 32 levels; a PNG pixel here is a whole byte for each of the
    # three, 256 levels a channel. Each level is stretched to fill the byte by repeating its
    # top bits into the bottom, so black stays black and full stays full — the same stretch a
    # screen showing the console's picture does.
    #
    # It uses no image tool: the compression is Ruby's own, so a picture can be written on a
    # machine that has nothing installed.
    module PNG
      SIGNATURE = Ractor.make_shareable([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A].pack("C*"))

      # How a pixel is stored, as the header says it: eight bits a channel; red, green and blue
      # with no table of colours between, or those three and how solid the pixel is. The three
      # noughts after that name the one way the format has of squeezing the rows and of
      # filtering them, and say the rows come in order and not interlaced.
      SOLID_PIXELS = Ractor.make_shareable([8, 2, 0, 0, 0].pack("C5"))
      PIXELS_WITH_ALPHA = Ractor.make_shareable([8, 6, 0, 0, 0].pack("C5"))

      module_function

      # The bytes of a PNG picture +width+ across and +height+ down. +pixels+ are the console's
      # colours, a row at a time from the top.
      #
      # +alpha+ makes it a picture with see-through parts, which is what a sprite's art is: how
      # solid each pixel is, in the same order, from 0 (see-through) to 255 (solid). Left out,
      # every pixel is solid.
      def encode(width:, height:, pixels:, alpha: nil)
        refuse_wrong_size!(width, height, pixels, alpha)
        refuse_alpha_outside_byte!(alpha) if alpha
        rows = (+"").b
        pixels.each_slice(width).with_index do |row, y|
          rows << "\0" # this row is stored as it stands
          row.each_with_index do |colour, x|
            rows << eight_bit_channels(colour)
            rows << [alpha[(y * width) + x]].pack("C") if alpha
          end
        end
        SIGNATURE + chunk("IHDR", [width, height].pack("N2") + (alpha ? PIXELS_WITH_ALPHA : SOLID_PIXELS)) +
          chunk("IDAT", Zlib::Deflate.deflate(rows)) + chunk("IEND", "".b)
      end

      # Write that picture to +path+, which is handed back.
      def write(path, **picture)
        File.binwrite(path, encode(**picture))
        path
      end

      # One chunk: how long its data is, its type, the data, and a check over the last two.
      def chunk(type, data)
        body = type.b + data
        [data.bytesize].pack("N") + body + [Zlib.crc32(body)].pack("N")
      end

      # A colour's red, green and blue as three bytes.
      def eight_bit_channels(colour)
        [0, 5, 10].map { |shift| (colour >> shift) & 0x1F }.map { |level| (level << 3) | (level >> 2) }.pack("C3")
      end

      # A picture with no width or no height is a file no viewer opens. One handed over with
      # the wrong number of pixels would come out sheared: every row after the first would
      # start in the wrong place.
      def refuse_wrong_size!(width, height, pixels, alpha)
        unless width >= 1 && height >= 1
          raise ArgumentError,
                "A picture cannot be #{width} by #{height}. Its width and its height must each be at least 1."
        end
        unless pixels.length == width * height
          raise ArgumentError,
                "A picture #{width} by #{height} has #{width * height} pixels. This one was given " \
                "#{pixels.length} pixels. Give one color for each pixel, a row at a time from the top."
        end
        return if alpha.nil? || alpha.length == pixels.length

        raise ArgumentError,
              "A picture #{width} by #{height} has #{pixels.length} pixels. Its alpha: has " \
              "#{alpha.length} #{alpha.length == 1 ? 'value' : 'values'}. Give one alpha value for each pixel, from 0 to 255."
      end

      # How solid a pixel is has one byte in the file.
      def refuse_alpha_outside_byte!(alpha)
        wrong = alpha.find { |value| !(0..255).cover?(value) }
        return if wrong.nil?

        raise ArgumentError,
              "An alpha: value of #{wrong} is not possible. Each value must be from 0 to 255. " \
              "0 is see-through and 255 is solid."
      end
      private_class_method :chunk, :eight_bit_channels, :refuse_wrong_size!, :refuse_alpha_outside_byte!
    end
  end
end
