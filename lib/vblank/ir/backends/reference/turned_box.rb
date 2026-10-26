# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Reference
        # WHICH ROWS OF THE SCREEN THE BOX OF A TURNED SPRITE IS SHOWN ON.
        #
        # A sprite that turns or resizes is drawn in a box twice its picture's size. A
        # display that draws sprites as objects counts the rows of that box in a fixed
        # number of lines, and a box that runs past the last line carries on from the
        # first. The screen is fewer lines than that, so the lines past its bottom edge
        # are where a box can stand unseen — and one box is taller than there are of
        # those: the box of a picture 64 pixels tall, which is 128 rows.
        #
        # So such a box, with its top near the bottom of the screen, runs past the last
        # line, and its END shows at the top of the screen. Hanging off the top by most of
        # its height, its START is counted as lines near the bottom of the screen and shows
        # there. Nothing a framework does can keep that part off: a display has no other
        # place to put a box that tall with some of it showing. What it can do, and does,
        # is keep a sprite off the screen altogether when none of its picture is on it,
        # which is the rule in #rows_shown — every backend keeps the same one.
        #
        # A shorter box never comes round, so for it this is the same as drawing the box
        # where it stands and cutting it off at the screen's edges.
        module TurnedBox
          # How many lines a display counts before it comes round to the first again.
          LINES = 256

          module_function

          # Each row of the box that shows, as [the row of the box, the row of the screen].
          #
          # +top+ is the screen row the box's first row stands at and +height+ how many
          # rows it has. +reached+ is the rows of it the picture can reach (see
          # Affine#rows_reached): with none of those on the screen the sprite is not drawn
          # at all, wherever its box would come round to.
          def rows_shown(top, height, reached, screen_height)
            return [] unless top + reached.end > 0 && top + reached.begin < screen_height

            (0...height).filter_map do |row|
              line = (top + row) % LINES
              [row, line] if line < screen_height
            end
          end
        end
      end
    end
  end
end
