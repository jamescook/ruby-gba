# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # WHAT A PAINTED SCREEN'S GAME PAINTS WITH, worked out while the game is built: its colours,
        # its pictures and text in the form Runtime::Paint copies them onto the screen, and the
        # rows it clears the screen with.
        #
        # THE COLOURS. A painted screen is one background of tiles whose pixels are eight bits each
        # (Runtime::Paint), so every pixel is one of 256 colours from one list, the console's colour
        # memory (CGRAM). Every colour the game can paint is known before it runs — each drawing
        # names its colours — so the list is made here, and the game paints a colour's place in it.
        # Place 0 is black: a pixel of place 0 is see-through on the console, and shows the colour
        # behind every layer, which is set to black too, the colour the screen starts in.
        #
        # A PICTURE is kept row by row, and each row as the tiles' rows it paints: a COLUMN of ten
        # bytes for every tile across it reaches — which of the tile's eight pixels the picture
        # draws (its MASK), twice, then the eight bits of their colours' places (its PLANES) in the
        # pairs a tile keeps them in (planes 0 and 1, 2 and 3...), leftmost pixel in the top bit, as
        # a tile of the console's keeps its pixels. So Runtime::Paint reads each 16-bit word ready to
        # write into a tile's row: the mask, then each pair of planes. A picture painted at a place
        # across that is not a multiple of eight falls across one tile more than its width, its
        # pixels shifted along; each row is kept for all eight places across modulo eight, one after
        # the other, so the painting never shifts anything.
        class PaintedArt
          COLORS = 256
          BLACK = 0
          # The mask and the eight planes.
          ROWS_A_ROW = 9
          # A column's bytes: the mask twice, then the planes; and the places across modulo eight.
          COLUMN_BYTES = 10
          SHIFTS = 8

          # Raised when the game paints more colours than the console's colour memory holds.
          class TooMuch < LoweringError; end

          # One picture as Runtime::Paint reads it: its number, its size, how many tiles across a row
          # of it reaches (its bytes across, and one for a place off the tile edges), and its rows,
          # each SHIFTS runs of that many columns.
          Picture = Data.define(:number, :width, :height, :across, :rows) do
            def row_bytes = SHIFTS * across * COLUMN_BYTES
          end

          attr_reader :pictures

          def initialize
            @colors = [BLACK]
            @places = { BLACK => 0 }
            @pictures = []
            @numbered = {}
          end

          # The place of +color+ (15-bit) in the colour list, added there the first time.
          def place_of(color)
            @places[color] ||= begin
              if @colors.length >= COLORS
                raise TooMuch, "This game paints more than #{COLORS} different colours. A Super Nintendo shows " \
                               "#{COLORS} colours on a painted screen. To fix this, use fewer colours."
              end
              @colors << color
              @colors.length - 1
            end
          end

          # The picture +key+ names, made once from a block that gives the picture's width, height and
          # the colour of each drawn pixel ({[x, y] => color}).
          def picture(key)
            @numbered[key] ||= begin
              width, height, drawn = yield
              made = make_picture(@pictures.length, width, height, drawn)
              @pictures << made
              made
            end
          end

          # How many of the colour memory's colours the game paints in, from colour 0: the rest are
          # black and never painted with.
          def colors_painted = @colors.length

          # The colour list as the console's colour memory takes it: 256 colours, two bytes each.
          def cgram
            @colors.dup.fill(BLACK, @colors.length...COLORS).pack("v*")
          end

          private

          def make_picture(number, width, height, drawn)
            across = ((width + 7) / 8) + 1
            rows = Array.new(height) do |y|
              (0...SHIFTS).map do |shift|
                (0...across).map { |column| column_bytes(drawn, width, y, (column * 8) - shift) }.join
              end.join
            end
            Picture.new(number: number, width: width, height: height, across: across, rows: rows)
          end

          # The column of a picture's row +y+ whose eight pixels start at its pixel +left+ (which may
          # be off its left or right edge): the mask twice, then planes 0 to 7.
          def column_bytes(drawn, width, y, left)
            planes = Array.new(ROWS_A_ROW, 0)
            8.times do |bit|
              x = left + bit
              color = drawn[[x, y]] if x.between?(0, width - 1)
              next if color.nil?

              planes[0] |= 0x80 >> bit
              place = place_of(color)
              8.times { |plane| planes[plane + 1] |= 0x80 >> bit if place[plane] == 1 }
            end
            [planes[0], *planes].pack("C*")
          end
        end
      end
    end
  end
end
