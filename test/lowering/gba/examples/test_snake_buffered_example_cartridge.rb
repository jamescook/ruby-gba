# frozen_string_literal: true

require "test_helper"

require "stringio"
require VBlank.root.join("examples/snake_buffered").to_s

# The buffered Snake example (examples/snake_buffered.rb) on the Advance's cartridge: its frame
# rate measured by the profiler, and its title and playing board read in the emulator — through
# Mode 4's auto palette and page flip, with the whole board repainted each frame. That it builds
# without a budget warning is in test/console/gba/examples/test_snake_buffered_example.rb.
class TestSnakeBufferedExampleCartridge < Minitest::Test
  include VBlank::Console::Hardware

  # ...and it really keeps up, which is the question the note on the build's test says an
  # estimate could not settle. Measured on the game as it opens.
  def test_it_holds_sixty_frames_a_second
    require_emulator!
    rom = BufferedSnake.build_rom(err: StringIO.new, profile: false)

    refute_predicate VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false), :dropping_frames?
  end

  # The title screen shows "SNAKE" in green — the simplest proof it isn't a black
  # screen, and that draw_text renders through the buffered (indexed) screen.
  def test_the_title_renders_on_the_console
    v = assert_emulator_loads_rom(BufferedSnake.build_rom(err: StringIO.new), frames: 4)
    title_green = (56..62).any? { |y| (105..134).any? { |x| v.green?(x, y) } }
    assert title_green, "the SNAKE title should render green in buffered mode"
  end

  # Pressing START enters play, where the whole board is repainted every frame: the
  # gray wall frame and the green snake body must render. A few frames in, the snake
  # is still near its start cells (row 10, moving right), so those are on screen.
  def test_the_playing_board_renders_on_the_console
    v = assert_emulator_loads_rom(BufferedSnake.build_rom(err: StringIO.new), frames: 8, keys: KEY_START)

    assert v.pixel_is?(120, 18, :gray),
           "the top wall should render gray, got 0x#{format('%04X', v.pixel_gba(120, 18))}"
    body_green = (80..87).any? { |y| (40..110).any? { |x| v.green?(x, y) } }
    assert body_green, "the snake body should render green (the whole board is repainted each frame)"
  end
end
