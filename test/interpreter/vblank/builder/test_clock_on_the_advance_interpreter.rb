# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/builder/test_clock_on_the_advance"

# The Advance's clock on the interpreter told to make a pass take several frames, which only the
# interpreter can be told. What the clock reads on every run that plays the Advance's games is in
# test/console/gba/vblank/builder/test_clock_on_the_advance.rb.
class TestClockOnTheAdvanceInterpreter < Minitest::Test
  include ClockOnTheAdvanceGames

  # A pass the console took three frames over still lets three frames of time go by: the clock
  # keeps real time, not the game's. Twenty passes of three frames are a second.
  def test_a_late_pass_lets_its_frames_of_time_go_by
    player = game_player.clock_at(THURSDAY).frames_each_pass { 3 }.run(program, frames: 20)

    assert_equal 6, player[:second]
  end
end
