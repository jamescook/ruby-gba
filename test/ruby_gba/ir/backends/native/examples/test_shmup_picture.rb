# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/shmup").to_s

# examples/shmup.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, over a recorded run: the ship flown right and left with a shot fired, then left alone
# until its last ship is lost, the field dims away under the score, and the game-over screen
# comes up; then START, and a fresh game. Its variables match on every frame too.
class TestShmupPicture < Minitest::Test
  include NativeComparison

  # Right, a shot, left again, then nothing held while the enemies take every ship. START is
  # tapped three times well after that: the first tap that lands on the game-over screen starts
  # the new game, and one that lands while playing does nothing.
  RUN = Ractor.make_shareable(
    NativeComparison.held_for([2..30, :right], [40..60, :left])
                    .merge(10 => %i[right a], 480 => [:start], 520 => [:start], 560 => [:start])
  )
  FRAMES = 600

  def test_shmup_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Shmup::GAME, err: nil)

    last = assert_recorded_run_matches_reference(program, frames: FRAMES, buttons: RUN)

    moments = reference_snapshots(program, frames: FRAMES, buttons: RUN)
    assert(moments.any? { |moment| moment.variables[:leaving] == 1 }, "the field should have dimmed away under the score")
    over = moments.index { |moment| moment.variables[:state] == Shmup::GAME_OVER }
    refute_nil over, "and the game-over screen come up"
    assert(moments.drop(over).any? { |moment| moment.variables[:lives] == 3 }, "and START should have begun a fresh game")
    assert_equal Shmup::PLAYING, last.variables[:state], "which is still being played at the end"
  end
end
