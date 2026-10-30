# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/snake").to_s

# The Snake example as a whole (examples/snake.rb). This is the capstone POC game;
# the focused move/collision core lives in test_snake_core.rb. Here we prove the
# shipped example *builds* — which runs the guardrails and the ROM-image checks
# automatically. That its first frames actually render on the console, so the
# classic silent-black-screen failure can't slip through, is checked on the Advance's
# cartridge in test/lowering/gba/examples/test_snake_example_cartridge.rb.
#
# The example draws the board incrementally (paint once, then only touch the cells
# that change each step) so the per-frame work stays inside the console's vblank
# window — a full redraw every frame overruns it and tears once the snake grows.
class TestSnakeExample < Minitest::Test
  # AC: examples/snake.rb builds clean. VBlank.build runs the guardrails (raising
  # on any fatal footgun) and the ROM-image validation, so calling it is the check.
  def test_the_example_builds_clean
    rom = Snake.build_rom(out: nil, err: nil)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end
end
