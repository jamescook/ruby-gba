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
        # A PICTURE is kept row by row, and each row as nine rows of bytes, a byte for every eight
        # pixels across: which of them the picture draws (its MASK), then each of the eight bits of
        # their colours' places (its PLANES), leftmost pixel in the top bit — the way a tile of the
        # console's keeps its pixels. Painted at a place across that is a multiple of eight, a byte of
        # the picture is a byte of a tile; anywhere else it falls across two, and Runtime::Paint
        # shifts it there as it paints. So each row of bytes is stored right to left, with an empty
        # byte at each end: the 16-bit number read at any byte then holds the picture's byte and the
        # one left of it, in the order a shift right moves the left one's pixels into it.
        class PaintedArt
          COLORS = 256
          BLACK = 0
          # Mask and the eight planes.
          ROWS_A_ROW = 9

          # Raised when the game paints more colours than the console's colour memory holds.
          class TooMuch < LoweringError; end

          # One picture as Runtime::Paint reads it: its number, its size, how many bytes each of its
          # rows of bytes holds (the bytes across, and the two empty ends), and its rows, each a
          # string of ROWS_A_ROW rows of bytes.
          Picture = Data.define(:number, :width, :height, :across, :rows) do
            def row_bytes = across * ROWS_A_ROW
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

          # The colour list as the console's colour memory takes it: 256 colours, two bytes each.
          def cgram
            @colors.dup.fill(BLACK, @colors.length...COLORS).pack("v*")
          end

          # One row of tiles of the screen (32 tiles side by side, 64 bytes each) all in the colour
          # at +place+: what clearing the screen copies, once for each row of tiles.
          def clear_row(place)
            tile = (0...4).flat_map do |pair|
              low = place[pair * 2] == 1 ? 0xFF : 0
              high = place[(pair * 2) + 1] == 1 ? 0xFF : 0
              [low, high] * 8
            end
            tile.pack("C*") * 32
          end

          private

          def make_picture(number, width, height, drawn)
            bytes_across = (width + 7) / 8
            across = bytes_across + 2
            rows = Array.new(height) do |y|
              planes = Array.new(ROWS_A_ROW) { Array.new(bytes_across, 0) }
              width.times do |x|
                color = drawn[[x, y]]
                next if color.nil?

                bit = 0x80 >> (x % 8)
                planes[0][x / 8] |= bit
                place = place_of(color)
                8.times { |plane| planes[plane + 1][x / 8] |= bit if place[plane] == 1 }
              end
              planes.map { |row| [0, *row.reverse, 0].pack("C*") }.join
            end
            Picture.new(number: number, width: width, height: height, across: across, rows: rows)
          end
        end
      end
    end
  end
end
