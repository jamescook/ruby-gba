# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/builder/test_blit_clipping"

# Edge clipping for blit on the Advance's cartridge: the cases of
# test/console/gba/vblank/builder/test_blit_clipping.rb, read in the emulator, held to the same
# visible pixels the interpreter shows. The console is where a per-row DMA that ignored the clip
# would wrap garbage onto the neighbouring line.
class TestBlitClippingCartridge < Minitest::Test
  include BlitClippingCases

  # Play a case on the console and assert each [x, y, colour] expectation holds.
  private def assert_clipped_on_the_console(defn, blit_stmt, expectations)
    prog = clip_program(defn, blit_stmt)
    rom = VBlank::Cartridge::ROM.assemble(GBA.new.lower(prog), title: "CLIPTEST", code: "BCLP", maker: "01")
    v = assert_emulator_loads_rom(rom)
    expectations.each do |x, y, color|
      assert v.pixel_is?(x, y, color || BG),
             "on the Advance's cartridge: (#{x}, #{y}) should be #{color || 'background'}, " \
             "got 0x#{format('%04X', v.pixel_gba(x, y))}"
    end
  end

  def test_clips_off_the_left_edge_on_the_console = assert_clipped_on_the_console(*left_edge_case)
  def test_clips_off_the_right_edge_on_the_console = assert_clipped_on_the_console(*right_edge_case)
  def test_clips_off_the_top_edge_on_the_console = assert_clipped_on_the_console(*top_edge_case)
  def test_clips_off_the_bottom_edge_on_the_console = assert_clipped_on_the_console(*bottom_edge_case)
  def test_clips_off_the_top_left_corner_on_the_console = assert_clipped_on_the_console(*top_left_corner_case)
  def test_a_fully_off_screen_blit_draws_nothing_on_the_console = assert_clipped_on_the_console(*fully_off_screen_case)

  def test_transparent_blit_clips_off_the_left_edge_on_the_console
    assert_clipped_on_the_console(*transparent_left_edge_case)
  end
end
