# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/snake").to_s

# examples/snake.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, over a recorded game: the title, START, the snake steered onto two apples and then
# left to run into a wall, the game-over screen, and START again for a second game. Its
# variables and its sound log — a beep for each apple and one as it dies — match on every frame.
#
# The game keeps its best score in save memory (`save_var`), so it is also switched off and on
# again here, and the best score is still there.
class TestSnakePicture < Minitest::Test
  include NativeComparison

  PLAYING = 1
  GAME_OVER = 2

  # START on the title, which also settles where the apples fall (the title stirs the random
  # numbers every frame it waits). A turn up meets the first apple and a turn right the second;
  # then nothing, and the snake meets the right wall around frame 154. START again for a new
  # game.
  RUN = Ractor.make_shareable(
    NativeComparison.held_for([3..4, :start], [28..33, :up], [52..57, :right], [170..171, :start])
  )
  GAME_OVER_BY = 160

  private def program = Native.new.checked_program(Snake::GAME, err: nil)

  def test_snake_matches_the_interpreter_through_a_recorded_game
    last = assert_native_matches_reference(program, frames: 200, buttons: RUN)

    assert_equal PLAYING, last.variables[:state], "the run should end in a second game"
    assert_equal [0, 2], last.variables.values_at(:score, :high_score), "with the first game's two apples kept as the best"
    assert_equal 3, last.sounds.count { |entry| entry.first == :beep }, "two apples and a death in the log compared"
  end

  # The same game played from a new cartridge, and then the cartridge switched on again.
  def test_the_best_score_is_still_there_when_the_game_is_switched_on_again
    store = SaveImage.new
    played = CheckedNativeRun.new(save: store).input_each_frame { |frame| RUN.fetch(frame, []) }
                             .run(program, frames: GAME_OVER_BY)
    assert_equal [GAME_OVER, 2], [played[:state], played[:high_score]]

    again = CheckedNativeRun.new(save: store).run(program, frames: 3)

    assert_equal 2, again[:high_score]
  end
end
