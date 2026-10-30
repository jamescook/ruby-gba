# frozen_string_literal: true

require "test_helper"

# A font a game defines, on the Advance's cartridge: its glyphs read back in the emulator. How a
# font is defined, and what it draws on every run, is in
# test/all/vblank/graphics/test_font_authoring.rb.
class TestFontAuthoringCartridge < Minitest::Test
  # A pictured font renders the same as a typed-in one, on the console as well.
  def test_a_pictured_font_renders_on_hardware
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      font :plus, glyphs: { "A" => [[0, 1, 0], [1, 1, 1], [0, 1, 0]] }
      draw_text "A", 40, 40, :red, font: :plus
      halt
    end
    builder.finalize_program
    rom = ROM.assemble(GBA.new.lower(builder.program), title: "FONTPIC", code: "BFPC", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 2)
    assert v.red?(41, 40), "the plus's top arm"
    assert v.red?(40, 41), "the plus's left arm"
    assert v.black?(40, 40), "the plus's empty corner"
  end

  # A live number in a game's own font whose figures are not all one width: the console's
  # shared digit routine needs them to be, so each digit is drawn as one of ten pieces of text,
  # and those must still find the game's font. Each digit here is one row that lights its own
  # column, and the last column always, so the font is nine wide — but its "1" is a column
  # shorter.
  def test_a_live_number_in_a_ragged_font_of_the_games_own_renders_on_hardware
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      font :ruler, glyphs: (0..9).to_h { |k|
        width = k == 1 ? 8 : 9
        [k.to_s, [Array.new(width) { |x| x == k || x == width - 1 ? 1 : 0 }]]
      }
      count = var :count, 7
      draw_number count, 40, 40, :red, digits: 1, font: :ruler
      halt
    end
    builder.finalize_program
    rom = ROM.assemble(GBA.new.lower(builder.program), title: "FONTWIDE", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 2)
    assert v.red?(47, 40), "the seven's own column"
    assert v.black?(43, 40), "and not another digit's"
  end

  def test_a_custom_font_renders_on_hardware
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      font :plus do
        glyph "A", <<~ART
          .#.
          ###
          .#.
        ART
      end
      draw_text "A", 40, 40, :red, font: :plus
      halt
    end
    builder.finalize_program
    rom = ROM.assemble(GBA.new.lower(builder.program), title: "FONTDEF", code: "BFDF", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 2)
    assert v.red?(41, 40), "the plus's top arm"   # (.#.) middle column, row 0
    assert v.red?(40, 41), "the plus's left arm"   # (###) row 1
    assert v.black?(40, 40), "the plus's empty corner"
  end
end
