# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # A SPRITE PICTURE CUT INTO SQUARES OF 8×8. The Color and the Super Nintendo both show a sprite
      # as pieces of eight pixels square, each one entry of the console's sprite table drawn from a
      # tile of its own, so a picture bigger than one square is shown as several placed side by side.
      # A square with nothing drawn in it is left out: it would take an entry of the table and show
      # nothing. What each pixel's number is — its place in a list of colours — is the console's;
      # where the squares fall, and which are left out, is the same on both.
      module SpritePieces
        SIZE = 8

        # The picture +width+ by +height+ pixels cut into squares, row by row from the top left, as
        # [across, down, the square's 64 numbers] with across and down in pixels. The block gives the
        # number at x, y inside the picture; past its right or bottom edge a square's pixels are 0. A
        # square that is 0 all over is left out. On a console told to draw its pieces taller
        # (+piece_height+ 16, the Color's 8×16), each is that tall, its numbers row after row.
        def self.cut(width, height, piece_height: SIZE)
          (0...height).step(piece_height).flat_map do |down|
            (0...width).step(SIZE).filter_map do |across|
              square = Array.new(SIZE * piece_height) do |i|
                x = across + (i % SIZE)
                y = down + (i / SIZE)
                x >= width || y >= height ? 0 : yield(x, y)
              end
              [across, down, square] unless square.all?(&:zero?)
            end
          end
        end
      end
    end
  end
end
