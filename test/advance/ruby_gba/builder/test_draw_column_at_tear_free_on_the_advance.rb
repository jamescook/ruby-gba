# frozen_string_literal: true

require "test_helper"
require "differential"

# The test of TestDrawColumnAtTearFree (in test_draw_column_at.rb) whose game paints the screen in
# more colours than a painted Game Boy Color screen holds at once, so it plays on the Advance's
# runs alone.
class TestDrawColumnAtTearFreeOnTheAdvance < Minitest::Test
  include EmulatorSupport
  include Differential

  BARS = %i[red red green green blue blue white white].freeze

  # The same program on either screen, so the two can be held against each other.
  private def column_program(tear_free:)
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: tear_free
      image :bars, width: 2, height: 4, data: BARS
      image(:ghost, "." => :transparent, "W" => :white) { "W\n.\n.\nW\n" }
      at = var :at, 0
      game_loop do
        # Repainted every pass, because this screen has TWO pages and the loop draws on
        # whichever one is hidden — a clear above the loop would paint only one of them.
        clear_screen :gray
        draw_column_at :bars, slice: 0, x: 10, top: 0, height: 8  # an even column...
        draw_column_at :bars, slice: 0, x: 11, top: 0, height: 8  # ...and an odd one
        at.set! 31 # a column whose evenness cannot be proved while building
        draw_column_at :bars, slice: 1, x: at, top: 10, height: 12
        repeat(4) { |c| draw_column_at :bars, slice: 0, x: (c * 2) + 60, top: 0, height: 6 }
        draw_column_at :ghost, slice: 0, x: 100, top: 0, height: 8
        draw_column_at :ghost, slice: 0, x: 101, top: 0, height: 8
        draw_column_at :bars, slice: 0, x: 120, top: -6, height: 20  # clipped above
        draw_column_at :bars, slice: 0, x: 121, top: 150, height: 40 # clipped below
        draw_column_at :bars, slice: 0, x: 239, top: 0, height: 8    # the last column
        draw_column_at :bars, slice: 0, x: 240, top: 0, height: 8    # off the right edge
        draw_column_at :bars, slice: 0, x: -1, top: 0, height: 8     # off the left edge

        # ...and the same as STRIPS, which write whole pairs where they can. Both parities,
        # a width that covers a pair exactly and one that does not, and both edges.
        draw_column_at :bars, slice: 0, x: 140, top: 20, height: 12, width: 3
        draw_column_at :bars, slice: 0, x: 151, top: 20, height: 12, width: 3
        draw_column_at :bars, slice: 0, x: 160, top: 20, height: 12, width: 2
        draw_column_at :bars, slice: 0, x: 171, top: 20, height: 12, width: 4
        draw_column_at :ghost, slice: 0, x: 180, top: 20, height: 12, width: 3
        draw_column_at :bars, slice: 0, x: 237, top: 20, height: 12, width: 5
        draw_column_at :bars, slice: 0, x: -2, top: 20, height: 12, width: 5
        at.set! 200
        draw_column_at :bars, slice: 0, x: at, top: 100, height: 12, width: 3
      end
    end
    b.finalize_program
    b.program
  end

  def test_the_console_draws_what_the_interpreter_draws
    assert_backends_agree(column_program(tear_free: true), frames: 3, name: "TFCOL")
  end
end
