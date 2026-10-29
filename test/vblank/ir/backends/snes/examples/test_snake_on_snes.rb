# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/snake").to_s

# examples/snake.rb on a Super Nintendo, laid out on its 256×224 screen: the title, a game steered
# into the top wall, the game-over screen and a second game — held to the interpreter after every
# pass, and played at the console's speed: the snake moves on every pass's one frame, and no frame
# shows half of one screen and half of the next.
class TestSnakeOnSNES < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  # START, then up until the snake meets the top wall, then START again from the game-over screen.
  def presses(frame)
    return [:start] if [20, 160].include?(frame)

    frame.between?(60, 64) ? [:up] : []
  end

  def test_a_game_is_played_over_and_started_again_like_the_interpreter
    run = game_player.input_each_frame { |frame| presses(frame) }
    run.run(Snake::GAME.program(console: game_console), frames: 200)

    assert_equal 1, run[:state], "the second game is being played"
    assert_equal 0, run[:score]
  end

  def test_the_board_fills_the_screen_and_every_frame_shows_one_whole_screen
    program = Snake::GAME.program(console: :snes)
    states = {}
    run = SNES::HeadlessRun.new(watch_picture: true).input_each_frame { |frame| presses(frame) }
    run.each_vblank { |pass| states[pass] = run[:state] }
    run.run(program, frames: 200)

    gray = VBlank::Graphics::Color.resolve(:gray)
    assert_equal gray, run.screen.pixel(252, 100), "the right wall is at the screen's right edge"
    assert_equal gray, run.screen.pixel(100, 220), "the bottom wall is at the screen's bottom"
    assert_empty run.black_frames
    assert_empty run.torn_frames
    assert_includes states.values, 2, "the game was over before it was started again"
    # A screen is painted whole once, as the game arrives at it — in the pass after the one that
    # chose it — and each pass on it after that takes one frame: the play, and the game-over
    # screen whose prompt blinks.
    [[1, 50, "a pass of play"], [2, 20, "a pass of the game-over screen"]].each do |state, at_least, what|
      passes = states.select { |pass, now| [now, states[pass - 1], states[pass - 2]].all?(state) }.keys
      assert_operator passes.length, :>, at_least
      assert_equal [1], passes.map { |pass| run.frames_took(pass) }.uniq, "#{what} takes one frame"
    end
  end
end
