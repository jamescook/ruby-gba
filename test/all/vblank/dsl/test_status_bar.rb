# frozen_string_literal: true

require "test_helper"
require "differential"
require "status_bar_games"

# What a game does with a status bar's handle as it runs: moves its top (`move_to`, read back with
# `top`), and changes one of its cells (`set_tile`). What the bar is and where it shows is the
# verb's own test, test/all/vblank/builder/test_status_bar.rb.
class TestStatusBarHandle < Minitest::Test
  include Differential
  include StatusBarGames

  # The game slides the bar down three rows a pass until it is out of view, and the field shows
  # at the bottom of the screen again. A row past the bottom is the bottom.
  def test_the_bar_slides_down_out_of_view_and_the_field_shows_under_it
    prog = bar_game { |bar, step| (step > 1).then { bar.move_to bar.top + 3 } }
    bottom = screen_height - 1

    assert_equal GREEN, picture(prog, 2).pixel(8, bottom)
    refute_equal GREEN, picture(prog, 12).pixel(8, bottom), "the bar is out of view"
    refute_equal BLACK, picture(prog, 12).pixel(8, bottom), "and the field is drawn there"
    assert_backends_agree(prog, frames: [4, 6, 12], name: "BARSLIDE")
  end

  # A row above the top of the screen is the top: the whole screen is the bar.
  def test_a_bar_moved_above_the_top_covers_the_whole_screen
    prog = bar_game { |bar, _step| bar.move_to(-20) }

    assert_equal GREEN, picture(prog, 4).pixel(8, 8)
    assert_equal BLACK, picture(prog, 4).pixel(8, 40), "past its two rows"
    assert_backends_agree(prog, frames: 4, name: "BARTOP")
  end

  # One cell of the bar changes, the way a digit of a score does.
  def test_set_tile_changes_a_cell_of_the_bar
    prog = bar_game { |bar, step| (step == 2).then { bar.set_tile 3, 0, "o" } }
    row = screen_height - 12

    assert_equal GREEN, picture(prog, 2).pixel(28, row)
    assert_equal BLUE, picture(prog, 5).pixel(28, row)
    assert_equal GREEN, picture(prog, 5).pixel(20, row), "the cell beside it"
    assert_backends_agree(prog, frames: 5, name: "BARCELL")
  end
end
