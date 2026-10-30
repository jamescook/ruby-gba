# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/snake").to_s

# The Snake example (examples/snake.rb) on the Advance's cartridge: its first frames read back
# in the emulator, so the classic silent-black-screen failure can't slip through. That the
# example builds clean is in test/console/gba/examples/test_snake_example.rb.
class TestSnakeExampleCartridge < Minitest::Test
  include VBlank::Console::Hardware

  CELL = Snake::CELL

  # AC: the initial render. On boot the title screen shows "SNAKE" in green — the
  # simplest proof the ROM isn't a black screen. Scans the title band rather than
  # pinning font pixels, so it survives font tweaks. Skips cleanly without the emulator.
  def test_the_title_screen_renders_on_the_console
    v = assert_emulator_loads_rom(Snake.build_rom(out: nil, err: nil), frames: 4)
    title_has_green = (56..62).any? { |y| (105..134).any? { |x| v.green?(x, y) } }
    assert title_has_green, "the SNAKE title should render in green — got a blank title screen"
  end

  # Pressing START paints the playing board once: the gray wall frame and the
  # opening snake (green body, white head). Holding START enters play; a few frames
  # in, the snake is still near its start cells, so those positions are defined.
  def test_the_opening_board_renders_on_the_console
    v = assert_emulator_loads_rom(Snake.build_rom(out: nil, err: nil), frames: 10, keys: KEY_START)

    # A body cell that stays green across the first step or two (cols 5..8, row 10).
    assert v.green?(7 * CELL + 3, 10 * CELL + 3), "the snake body should be drawn green"
    # The gray wall frame around the play area (left wall is column 0).
    assert v.pixel_is?(3, 10 * CELL + 3, :gray), "the play-field wall should be drawn gray"
  end
end
