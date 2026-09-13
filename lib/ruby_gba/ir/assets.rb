# frozen_string_literal: true

module RubyGBA
  module IR
    # WHAT A DECLARED ASSET IS, read off the node that declares it.
    #
    # A program declares images and recorded sounds, and every backend has to know the same
    # things about them: how big a picture is, which of its colors means "see through",
    # how fast a recording plays. Each backend used to write that down for itself, which is
    # two descriptions of one thing in the two places whose whole contract is that they
    # agree — and nothing but a test to notice when they drifted.
    #
    # These are built from the declaring node by one function, so there is one description
    # and the backends read it. What a backend then DOES with an asset is its own business
    # and stays there: where the GBA packed a table into the cartridge, or which hardware
    # layer a background got, means nothing to an interpreter and is not here.
    module Assets
      # A picture: its size, which color index is see-through (nil if none is), the
      # pixels themselves, and — where the art came from somewhere that already decided
      # them — its own table of colors in its own order (nil where it did not).
      Image = Data.define(:width, :height, :transparent, :pixels, :colors) do
        def self.of(node)
          new(width: node.width, height: node.height,
              transparent: node.transparent, pixels: node.pixels, colors: node.colors)
        end

        # ONE PIXEL, COUNTING ACROSS THE ROWS: pixel 0 is the top left, and the next is the
        # one to its right. Two bytes each, the low one first.
        #
        # TWO READINGS, AND THE DIFFERENCE MATTERS. +raw_at+ is the number the program wrote,
        # which is fifteen bits of color and a sixteenth bit that marks a pixel see-through —
        # so it is the one to compare against +transparent+, and #drawn_at? is that comparison.
        # +color_at+ drops that bit, and is the color the console shows. Reading the wrong one
        # is quiet: a see-through pixel would read as a real color nothing else uses, and turn
        # up as one more color in a picture's table.
        def raw_at(index) = pixels.getbyte(index * 2) | (pixels.getbyte((index * 2) + 1) << 8)

        def color_at(index) = raw_at(index) & 0x7FFF

        # Does this pixel draw anything? A picture with no see-through color draws every one.
        def drawn_at?(index) = transparent.nil? || raw_at(index) != transparent

        # THE SAME PICTURE THE OTHER WAY ROUND — every row read right to left.
        #
        # "Left is the right one, backwards" is close to universal in 2D games, and this
        # is the one place a picture is turned round. A program that SAYS a pose is a
        # mirror and a build that NOTICES one already is therefore compare the same bytes,
        # which is what lets the second recognize the first.
        def mirrored
          turned = (0...height).each_with_object(+"".b) do |row, bytes|
            bytes << pixels.byteslice(row * width * 2, width * 2).unpack("v*").reverse.pack("v*")
          end
          with(pixels: turned)
        end
      end

      # A recorded sound: how many samples a second it was recorded at, how many there are,
      # and the note it was played at when recorded (which is what playing it at another
      # pitch is measured from).
      # +holds_from+ is where a held note reads back to at the end of the recording, as a sample
      # number, or nil for one that runs out. It is kept as HOW FAR BACK that is rather than
      # where it starts, because that is what a voice needs: the mixer moves its read pointer
      # back by this when it reaches the end, which is one subtraction and no arithmetic about
      # where the recording began.
      Sample = Data.define(:rate, :length, :note, :envelope, :holds_from) do
        def self.of(node)
          new(rate: node.rate, length: node.bytes.bytesize, note: node.note,
              envelope: node.envelope, holds_from: node.holds_from)
        end

        # How far a held note goes back at the end of the recording, or 0 for one that stops
        # there. A recording that holds from its very start goes back by the whole of it.
        def held_by = holds_from ? length - holds_from : 0
      end
    end
  end
end
