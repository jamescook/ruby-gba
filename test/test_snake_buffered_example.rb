# frozen_string_literal: true

require "test_helper"

require "stringio"
require_relative "../examples/snake_buffered"

# The buffered Snake example (examples/snake_buffered.rb): the demonstration that
# double buffering lets you write the naive "clear and repaint everything every
# frame" code and still play tear-free. Same game as examples/snake.rb, but drawn
# the simple way instead of incrementally — safe only because it's buffered.
#
# We prove it builds clean (which runs the guardrails and ROM-image checks) and
# renders its title and playing board on the console — through Mode 4's auto
# palette and page flip, with the whole board repainted each frame.
class TestSnakeBufferedExample < Minitest::Test
  include RubyGBA::Constants

  # RubyGBA.build runs the guardrails and validation, so a clean build IS the check.
  # The redraw-everything guardrail stays quiet here (buffering makes the whole-board
  # repaint tear-safe), and the one that speaks is the growth warning: repainting the
  # whole body every frame costs more the longer the snake gets, and a few hundred cells
  # no longer fit in a frame. That warning is the teaching point — buffering stops
  # tearing, not slowness.
  #
  # WHICH WARNING IS THE RIGHT ONE HERE was settled by measuring. This used to warn that
  # the game is too heavy for 60fps full stop, which the console disagrees with: it costs
  # a fraction of a frame with the four-cell snake it opens with, and grows past a whole
  # frame only once the body is a few hundred cells long. The cost is real and it arrives
  # WITH LENGTH, so the warning that names the length is the true one.
  def test_the_example_builds_and_warns_the_frame_grows_with_the_snake
    err = StringIO.new
    rom = BufferedSnake.build_rom(err: err)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
    assert_match(/goes over budget/, err.string, "the growing-list warning should fire")
    assert_match(/:xs/, err.string, "and it should name the list to cap")
  end

  # The title screen shows "SNAKE" in green — the simplest proof it isn't a black
  # screen, and that draw_text renders through the buffered (indexed) screen.
  def test_the_title_renders_on_the_console
    v = assert_gemba_loads_rom(BufferedSnake.build_rom(err: StringIO.new), frames: 4)
    title_green = (56..62).any? { |y| (105..134).any? { |x| v.green?(x, y) } }
    assert title_green, "the SNAKE title should render green in buffered mode"
  end

  # Pressing START enters play, where the whole board is repainted every frame: the
  # gray wall frame and the green snake body must render. A few frames in, the snake
  # is still near its start cells (row 10, moving right), so those are on screen.
  def test_the_playing_board_renders_on_the_console
    v = assert_gemba_loads_rom(BufferedSnake.build_rom(err: StringIO.new), frames: 8, keys: KEY_START)

    assert v.pixel_is?(120, 18, :gray),
           "the top wall should render gray, got 0x#{format('%04X', v.pixel_gba(120, 18))}"
    body_green = (80..87).any? { |y| (40..110).any? { |x| v.green?(x, y) } }
    assert body_green, "the snake body should render green (the whole board is repainted each frame)"
  end
end
