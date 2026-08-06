# frozen_string_literal: true

require "test_helper"

require_relative "../examples/snake"

# The Snake example as a whole (examples/snake.rb). This is the capstone POC game;
# the focused move/collision core lives in test_snake_core.rb. Here we prove the
# shipped example *builds* — which runs the guardrails and the ROM-image checks
# automatically — and that its first frames actually render on the console, so the
# classic silent-black-screen failure can't slip through.
#
# The example draws the board incrementally (paint once, then only touch the cells
# that change each step) so the per-frame work stays inside the console's vblank
# window — a full redraw every frame overruns it and tears once the snake grows.
class TestSnakeExample < Minitest::Test
  include RubyGBA::Constants

  CELL = Snake::CELL

  # AC: examples/snake.rb builds clean. RubyGBA.build runs the guardrails (raising
  # on any fatal footgun) and the ROM-image validation, so calling it is the check.
  def test_the_example_builds_clean
    rom = Snake.build_rom
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # AC: the initial render. On boot the title screen shows "SNAKE" in green — the
  # simplest proof the ROM isn't a black screen. Scans the title band rather than
  # pinning font pixels, so it survives font tweaks. Skips cleanly without gemba.
  def test_the_title_screen_renders_on_the_console
    v = assert_gemba_loads_rom(Snake.build_rom, frames: 4)
    title_has_green = (56..62).any? { |y| (105..134).any? { |x| v.green?(x, y) } }
    assert title_has_green, "the SNAKE title should render in green — got a blank title screen"
  end

  # Pressing START paints the playing board once: the gray wall frame and the
  # opening snake (green body, white head). Holding START enters play; a few frames
  # in, the snake is still near its start cells, so those positions are defined.
  def test_the_opening_board_renders_on_the_console
    v = assert_gemba_loads_rom(Snake.build_rom, frames: 10, keys: KEY_START)

    # A body cell that stays green across the first step or two (cols 5..8, row 10).
    assert v.green?(7 * CELL + 3, 10 * CELL + 3), "the snake body should be drawn green"
    # The gray wall frame around the play area (left wall is column 0).
    assert v.pixel_is?(3, 10 * CELL + 3, :gray), "the play-field wall should be drawn gray"
  end
end
