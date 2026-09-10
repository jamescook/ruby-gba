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
  # This game used to warn that its frame goes over budget past about 419 cells. It no
  # longer does, and the warning was wrong rather than the check being broken: it was
  # priced before the build had decided anything, so it charged cartridge speed for a
  # frame the build actually keeps in the console's quick memory. The build keeps five of
  # this game's routines there AND the frame body, which takes the every-frame cost from
  # about 58 scanlines to about 40 — and a full 448-cell board then fits inside the 228 a
  # frame has.
  #
  # So the game builds clean, and the assertion is that nothing shouts about a budget it
  # does not exceed. What is NOT settled is whether a full board really fits on the
  # console: the one measurement on record here is of the four-cell snake the game opens
  # with. That is a question for a measured run rather than for either estimate.
  def test_the_example_builds_without_a_budget_warning
    err = StringIO.new
    rom = BufferedSnake.build_rom(err: err)

    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
    refute_match(/goes over budget/, err.string,
                 "priced with the build's own answers, a full board fits in a frame")
  end

  # ...and it really keeps up, which is the question the note above says an estimate could
  # not settle. Measured on the game as it opens.
  def test_it_holds_sixty_frames_a_second
    require_gemba_core!
    rom = BufferedSnake.build_rom(err: StringIO.new, profile: false)

    refute_predicate RubyGBA::Profiler.run(rom, frames: 30, picture: false), :dropping_frames?
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
