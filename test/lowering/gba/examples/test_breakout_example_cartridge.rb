# frozen_string_literal: true

require "test_helper"

require "stringio"
require VBlank.root.join("examples/breakout").to_s

# The Breakout example (examples/breakout.rb) on the Advance's cartridge: the picture really
# renders, read from settled frames in the emulator. What the game does is in
# test/console/gba/examples/test_breakout_example.rb and test/console/gbc/examples/test_breakout_example.rb.
class TestBreakoutExampleCartridge < Minitest::Test
  include VBlank::Console::Hardware

  # The title shows "BREAKOUT" in cyan — the simplest proof it isn't a black screen
  # and that text renders through the buffered (indexed) screen.
  def test_the_title_renders_on_the_console
    v = assert_emulator_loads_rom(Breakout.build_rom(err: StringIO.new), frames: 4)
    title_cyan = (50..57).any? { |y| (92..140).any? { |x| v.pixel_is?(x, y, :cyan) } }
    assert title_cyan, "the BREAKOUT title should render cyan in buffered mode"
  end

  # Pressing START enters play, where the wall and paddle are painted every frame.
  # A few frames in, the ball is still climbing toward the wall, so every brick is
  # up: the red top row and the white paddle must both render.
  def test_the_wall_and_paddle_render_on_the_console
    v = assert_emulator_loads_rom(Breakout.build_rom(err: StringIO.new), frames: 8, keys: KEY_START)

    top_row_red = (18..27).any? { |y| (0..238).any? { |x| v.red?(x, y) } }
    assert top_row_red, "the red top row of bricks should render"

    paddle_white = (150..155).any? { |y| (104..136).any? { |x| v.white?(x, y) } }
    assert paddle_white, "the white paddle should render near the bottom"
  end
end
