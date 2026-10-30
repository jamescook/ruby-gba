# frozen_string_literal: true

require "test_helper"

# The `table` verb on the Advance's cartridge: a lookup drives real pixels, read in the
# emulator. What a lookup returns, asked of every run, is in test/all/vblank/test_table.rb.
class TestTableCartridge < Minitest::Test
  private def rom_for(title, code, &block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    ROM.assemble(GBA.new.lower(b.program), title: title, code: code, maker: "01")
  end

  # --- Hardware (the emulator): the lookup drives real pixels ---

  # A table of x-positions drives a rect's position on the console: the rect lands at
  # the value the lookup returned, proving the runtime read works on hardware.
  def test_a_table_value_positions_a_rect_on_the_console
    rom = rom_for("TABLE", "BTBL") do
      screen :bitmap
      clear_screen :black
      xs = table :xs, [10, 80, 150], width: :half # non-power-of-two -> clamps
      draw_rect_at xs[1], 40, 8, 8, :white         # a white 8x8 at x = xs[1] = 80
      halt
    end
    v = assert_emulator_loads_rom(rom, frames: 2)
    assert v.white?(83, 43), "the rect drew at the table's x (80), got 0x#{format('%04X', v.pixel_gba(83, 43))}"
    assert v.black?(20, 43), "elsewhere stays background"
  end

  # A signed table read must sign-extend on hardware (the ldrsh path): a negative
  # offset moves the rect UP from a base y, so a wrong (unsigned) read would misplace it.
  def test_a_signed_table_read_sign_extends_on_the_console
    rom = rom_for("TSIGN", "BTSG") do
      screen :bitmap
      clear_screen :black
      dy = table :dy, [-24, 0, 24], width: :half # signed inferred; index 0 is -24
      var :y, 80
      add! :y, dy[0]                              # y = 80 + (-24) = 56
      draw_rect_at 100, :y, 8, 8, :white
      halt
    end
    v = assert_emulator_loads_rom(rom, frames: 2)
    assert v.white?(103, 59), "a signed -24 moved the rect to y=56, got 0x#{format('%04X', v.pixel_gba(103, 59))}"
    assert v.black?(103, 83), "the rect is not at the base y (80)"
  end
end
