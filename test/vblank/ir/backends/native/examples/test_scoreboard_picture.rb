# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require VBlank.root.join("examples/scoreboard").to_s

# examples/scoreboard.rb built for the desktop shows the interpreter's picture pixel for pixel,
# frame by frame, while the ball goes low and the score bar slides out of its way, then comes back
# up as the ball rises, lighting its pips once a second throughout.
class TestScoreboardPicture < Minitest::Test
  include NativeComparison

  DOWN_THEN_UP = Ractor.make_shareable(NativeComparison.held_for([2..60, :down], [61..150, :up]))

  def test_scoreboard_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Scoreboard::GAME, err: nil)

    last = assert_recorded_run_matches_reference(program, frames: 160, buttons: DOWN_THEN_UP)

    assert_equal 2, last.variables[:lit], "a pip a second, for the two seconds and more played"
  end
end
