# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_text_placement"

# Text placed without counting pixels, on the Advance's cartridge: where its letters and
# sprites really land, read back in the emulator. Where the text goes on every run is in
# test/all/vblank/builder/test_text_placement.rb.
class TestTextPlacementCartridge < Minitest::Test
  include TextPlacementGames

  # On a tiled screen each character is its own little sprite, and a sprite can stand
  # at any column — so the letters advance by their own widths there too, and "IM" is
  # 7 across on either screen rather than spaced for an M twice. Asked of the console,
  # since it is the console that places the sprites.
  def test_a_tiled_screen_spaces_a_proportional_font_by_each_letter
    left = (SCREEN - IM_WIDE) / 2
    v = assert_emulator_loads_rom(assemble_rom(tiled_vari_program, name: "TILEDVARI"), frames: 3)
    assert_equal [left, left + 2], v.sprites.map(&:x).sort, "the I is one pixel and a gap"
  end

  # A LIVE NUMBER KEEPS ITS COLUMNS, proportional font or not, so a digit that changes
  # never moves the ones beside it: "18" in a font where 1 is one pixel and 8 is five
  # still puts its 8 a whole cell along.
  def test_a_live_number_on_a_tiled_screen_keeps_a_column_per_digit
    program = live_digits_program
    cell = program.fonts.get(:digits).cell_w

    v = assert_emulator_loads_rom(assemble_rom(program, name: "LIVECOLS"), frames: 4)
    assert_equal [100, 100 + cell], v.sprites.map(&:x).sort
  end

  # --- and it lands centred on the real thing ------------------------------------

  def test_centred_text_is_centred_on_hardware
    b = Builder.new
    define_demo_font(b)
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      draw_text "IM", :center, Y, :white, font: :vari
      halt
    end
    b.finalize_program
    rom = ROM.assemble(GBA.new.lower(b.program), title: "CENTER", code: "BCTR", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 2)
    left = (SCREEN - IM_WIDE) / 2

    assert v.white?(left, Y), "the I sits where the font says the line starts"
    assert v.black?(left - 1, Y), "and not one pixel further left"
    assert v.white?(left + 6, Y), "the M's right stroke ends the line"
    assert v.black?(left + IM_WIDE, Y), "with nothing past it"
  end
end
