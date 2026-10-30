# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/grid_cursor").to_s

# examples/grid_cursor.rb on a Super Nintendo: a board of 32×28 cells, the bigger screen's, and a
# cursor stepped one cell a press and kept on it, held to the interpreter — every variable and
# every pixel — after every pass.
class TestGridCursorOnSNES < Minitest::Test
  # Started in the middle, stepped right past the board's right edge, then down and left.
  def test_the_cursor_steps_and_stays_on_the_board_like_the_interpreter
    presses = (0...40).to_h { |i| [3 + (i * 2), [:right]] }
                      .merge(90 => [:down], 92 => [:down], 94 => [:left])
    run = game_player.input_each_frame { |frame| presses.fetch(frame, []) }
    run.run(GridCursor::GAME.program(console: game_console), frames: 100)

    assert_equal [30, 16], [run[:cx], run[:cy]], "held at the last column, then down two and left one"
  end
end
