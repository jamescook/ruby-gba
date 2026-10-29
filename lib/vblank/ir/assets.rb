# frozen_string_literal: true

module VBlank
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
      #
      # +places+ is the same picture read the other way round: where the art was given as
      # numbers into that table, one byte a pixel saying which place it came from (nil
      # where the art was given as colors). The two are the same picture until the table
      # holds one color at two places, which a palette taken off a real cartridge usually
      # does — then a pixel's color no longer says which place drew it, and anything that
      # reads a pixel as a NUMBER has to ask here instead.
      #
      # +colors_name+ is the name of the list of colours it was drawn from, where the game named one
      # (`image ..., colors: :sea`), and nil where it gave the colours themselves. Two lists named
      # apart are two lists even when they hold the same colours — a screen brought in from white
      # starts with every list white — so a background told to draw each of its lists with
      # another tells them apart by #list_drawn_from, the name and the colours together.
      #
      # +pieces+ is, for a picture the game made of 8x8 pieces (`image ..., pieces:`), each piece
      # front-most first as [dx, dy, its 64 places]: where its top left is in the picture, and its
      # pixels as places in the picture's list, row by row. The picture's own pixels are those pieces
      # laid over each other, so a console that draws sprites from pieces can draw it from the same
      # ones; nil for any other picture.
      # The side of a piece of a picture made of pieces (Image#pieces).
      PIECE_SIZE = 8

      Image = Data.define(:width, :height, :transparent, :pixels, :colors, :places, :colors_name, :pieces) do
        def initialize(width:, height:, transparent:, pixels:, colors:, places:, colors_name: nil, pieces: nil) = super

        def self.of(node)
          new(width: node.width, height: node.height, transparent: node.transparent,
              pixels: node.pixels, colors: node.colors, places: node.places, colors_name: node.colors_name,
              pieces: (node.pieces if node.respond_to?(:pieces)))
        end

        # The list this picture was drawn from, as a background's recolouring keeps them apart.
        def list_drawn_from = [colors_name, colors]

        # Which place in the picture's own list this pixel was drawn at, or nil for a
        # picture whose art was given as colors and never recorded one.
        def place_at(index) = places&.getbyte(index)

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

        # Does the layer behind show through this pixel when the picture is a background
        # tile? A tile has no marker of its own for "nothing here", so it is the backdrop
        # color, black, that says it — except in art that came with its place numbers,
        # where place 0 says it and black at any other place is a color like the rest. Every
        # backend asks this one question, so a black pixel is solid or see-through on each.
        def tile_see_through_at?(index)
          place = place_at(index)
          place.nil? ? color_at(index).zero? : place.zero?
        end

        # EVERY COLOR THIS PICTURE ACTUALLY DRAWS, its see-through pixels left out. What a
        # picture was given and what it uses are different lists: a table can name colors no
        # pixel is painted in, which is how one picture ships a whole game's palette.
        #
        # Each colour once, in the order the pixels first draw it, row by row from the top
        # left — the order a table of colours built from the picture lists them in. Two values
        # that differ only in the see-through bit are one colour here.
        def colors_drawn
          Remembered.fetch(:colors_drawn, self) do
            pixels.unpack("v*").reject { |value| value == transparent }.map { |value| value & 0x7FFF }.uniq
          end
        end

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
          with(pixels: turned, places: places && mirrored_places,
               pieces: pieces&.map { |dx, dy, own| [width - dx - PIECE_SIZE, dy, Image.rows(own).map(&:reverse).join.b] })
        end

        # THE SAME PICTURE TURNED TOP TO BOTTOM — its rows in the other order. The other
        # mirror, and the one place a picture is turned that way, for the same reason as above.
        def upside_down
          rows = (0...height).map { |row| pixels.byteslice(row * width * 2, width * 2) }
          upended = places && (0...height).map { |row| places.byteslice(row * width, width) }.reverse.join.b
          with(pixels: rows.reverse.join.b, places: upended,
               pieces: pieces&.map { |dx, dy, own| [dx, height - dy - PIECE_SIZE, Image.rows(own).reverse.join.b] })
        end


        # A piece's 64 places, a row of eight at a time.
        def self.rows(own) = (0...PIECE_SIZE).map { |row| own.byteslice(row * PIECE_SIZE, PIECE_SIZE) }

        private

        def mirrored_places
          (0...height).each_with_object(+"".b) do |row, bytes|
            bytes << places.byteslice(row * width, width).reverse
          end
        end
      end

      # WHAT COLOR A PIXEL IS DRAWN IN while its picture is drawn with another list of colors:
      # each place of the picture's own list shows the color at the same place of that list.
      # A picture whose art was given as places is read by place, which is what a machine that
      # keeps a number per pixel does with it; one given as colors has only its colors to go
      # on. One of the two halves is filled in and the other is not, since a picture is one
      # kind or the other.
      #
      # It is the picture's business rather than any one backend's, so a backend that swaps
      # colors as it draws and one that makes its recolored pictures ahead of time ask the
      # same rule.
      Recolor = Data.define(:places, :by_place, :by_color) do
        # +picture+ (an Image) drawn with the list +swapped+.
        def self.of(picture, swapped)
          new(places: picture.places, by_place: swapped,
              by_color: picture.places ? nil : color_swaps(picture.colors, swapped))
        end

        # A picture given as COLORS has no places recorded, so its swap is read the only way
        # left: color to color, and a color its list holds twice is read at the first of
        # them. The build refuses that where the two places differ in the list being drawn
        # with, so this is only ever reached where both places agree.
        def self.color_swaps(own, swapped)
          (1...own.length).each_with_object({}) { |place, swaps| swaps[own[place]] ||= swapped[place] }
        end

        # The color pixel +index+ is drawn in, +color+ being the one the picture stores there.
        def color_for(index, color)
          return by_place[places.getbyte(index)] || color if places

          by_color.fetch(color, color)
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
        def loop_length = holds_from ? length - holds_from : 0
      end
    end
  end
end
