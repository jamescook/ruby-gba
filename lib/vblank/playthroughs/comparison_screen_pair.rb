# frozen_string_literal: true

module VBlank
  module Playthroughs
    class Comparison
      # THE TWO SCREENS TWO CARTRIDGES SHOWED AT ONE POINT, AND WHERE THEY DIFFER, as the
      # pictures a person looks at to see what a comparison found.
      #
      # +first+ and +second+ are the two screens, each a screenful of the console's colours a
      # row at a time from the top. +differing+ is where in that list the two hold different
      # colours, of the places that were looked at (see Likeness#differing_places): a part
      # of the screen a comparison was told to leave out is never in it, so nothing here
      # marks a pixel that was not what made the two differ.
      ScreenPair = Data.define(:first, :second, :differing)

      class ScreenPair
        # What a differing pixel is marked in: a colour a greyed screen cannot hold.
        MARK = Graphics::Color.resolve(:magenta)

        # How many times the console's size a panel of the side-by-side picture is. A
        # screen at its own size is a postage stamp on a monitor, and a single pixel out
        # is one nobody finds.
        SCALE = 2

        # How wide the strip between two panels is, in the picture's own pixels, and its
        # colour — so that two screens of one colour do not run into each other.
        STRIP_WIDTH = 8
        STRIP_COLOUR = Graphics::Color.resolve(:gray)

        WIDTH = Console::Hardware::SCREEN_WIDTH
        private_constant :MARK, :SCALE, :STRIP_WIDTH, :STRIP_COLOUR, :WIDTH

        # THE DIFFERENCE AS A SCREEN: the first screen with its colour taken out and dimmed,
        # so it is only there to say where on the screen things are, and every pixel that
        # differs in the mark's colour.
        def difference_screen
          marked = first.map { |colour| greyed(colour) }
          differing.each { |at| marked[at] = MARK }
          marked
        end

        # WRITE ONE PICTURE OF IT ALL at +path+, a PNG: the first screen, the second, and the
        # difference, left to right, each at SCALE times the console's size with a strip
        # between. +with_difference+ says whether the last is there, for somebody who wants
        # the two screens alone. The path is handed back.
        def write_side_by_side(path, with_difference: true)
          screens = with_difference ? [first, second, difference_screen] : [first, second]
          rows = rows_side_by_side(screens)
          Graphics::PNG.write(path, width: rows.first.size, height: rows.size, pixels: rows.flatten)
        end

        private

        # +screens+ as the rows of one picture, each screen a panel of it.
        def rows_side_by_side(screens)
          panels = screens.map { |screen| screen.each_slice(WIDTH).to_a }
          strip = Array.new(STRIP_WIDTH, STRIP_COLOUR)
          panels.first.each_index.flat_map do |row|
            across = panels.map { |panel| panel[row].flat_map { |colour| [colour] * SCALE } }
            [across.reduce { |left, right| left + strip + right }] * SCALE
          end
        end

        # A colour as the grey of half its brightness. The console keeps five bits each of
        # red, green and blue, lowest first.
        def greyed(colour)
          grey = ((colour & 31) + ((colour >> 5) & 31) + ((colour >> 10) & 31)) / 6
          grey | (grey << 5) | (grey << 10)
        end
      end
    end
  end
end
