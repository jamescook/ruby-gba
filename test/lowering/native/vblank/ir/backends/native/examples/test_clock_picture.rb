# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/clock").to_s

# examples/clock.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, with the windowless program's clock started at the same moment as the interpreter's:
# two seconds before a new year, so the face is repainted twice and the second time every line
# of it changes.
#
# It plays through `game_player` rather than the recorded-run helpers its neighbours use, because
# those cannot start a clock. On this run `game_player` is the checked player, which compares the
# same things with the interpreter on every frame: the variables, the picture, the sound and the
# sprites.
class TestClockPicture < Minitest::Test
  def test_clock_matches_the_interpreter_into_a_new_year
    player = game_player.clock_at(Time.new(2026, 12, 31, 23, 59, 58)).run(ClockFace.program, frames: 130)

    assert_equal 0, player[:shown], "the face last painted the first second of the new year"
  end
end
