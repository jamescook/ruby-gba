# frozen_string_literal: true

require "test_helper"
require "all/vblank/graphics/test_proportional_font"

# A PROPORTIONAL FONT ON THE ADVANCE'S CARTRIDGE, read in the emulator: the pen advances by each
# glyph's own width, and run-time digits are drawn at the digits' width. The font on every run is
# in test/all/vblank/graphics/test_proportional_font.rb.
class TestProportionalFontCartridge < Minitest::Test
  # Registers into the library itself, which changes the whole process — so on the
  # main Ractor, not in the pool. See test_helper.
  runs_on_the_main_ractor!

  include ProportionalFontGames

  def test_the_hardware_advances_by_the_glyphs_width
    builder = Builder.new
    define_demo_font(builder)
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      draw_text "IM", X, Y, :white, font: :vari
      halt
    end
    builder.finalize_program
    rom = ROM.assemble(GBA.new.lower(builder.program), title: "VARIFNT", code: "BVRF", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 2)

    assert v.white?(X, Y),          "the I is drawn at the origin"
    assert v.black?(X + 1, Y),      "the 1px I leaves a gap at x+1"
    assert v.white?(X + 2, Y),      "M starts right after the narrow I (proportional)"
    assert v.white?(X + 6, Y),      "M's right stroke — it really is 5 wide"
    assert v.black?(X + 7, Y),      "nothing is drawn past M"
  end

  # ---- run-time digits pick the DIGIT width, not the font's widest glyph ----

  # A proportional font whose ten digits are a uniform 3px but whose widest glyph is
  # a 5px "W". The data-driven digit path (a run-time score) must measure the digits'
  # own 3px, not the font's 5px max — read the 3-bit glyph rows as 5 bits and every
  # digit renders shifted and garbled. Only hardware exercises that loop (the
  # interpreter always reads a glyph at its own width), so this is an emulator check:
  # the run-time digit must match the same digit drawn as fixed text.
  private def register_hud_font
    wide_w = [0b10001, 0b10001, 0b10101, 0b11011, 0b10001] # 5 wide, 5 tall
    glyphs = VBlank::Graphics::Font::TINY_GLYPHS.merge("W" => wide_w) # tiny's digits are 3 wide
    widths = glyphs.keys.to_h { |k| [k, k == "W" ? 5 : 3] }
    Fonts.register(:hud, VBlank::Graphics::Font.new(glyphs: glyphs, widths: widths, height: 5))
  end

  def test_data_driven_digits_render_at_the_digit_width_on_hardware
    register_hud_font
    assert_equal 5, Fonts.get(:hud).width      # the widest glyph (W)
    assert_equal 3, Fonts.get(:hud).glyph_width("7") # but a digit is 3

    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      var :n, 7
      draw_number :n, 40, 20, :white, digits: 1, font: :hud # live -> data-driven loop
      draw_number 7,  40, 40, :white, digits: 1, font: :hud # fixed -> draw_text "7" unroll
    end
    builder.finalize_program
    rom = ROM.assemble(GBA.new.lower(builder.program), title: "HUDNUM", code: "BHDN", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 4)

    (0...3).each do |dx|
      (0...5).each do |dy|
        assert_equal v.pixel_gba(40 + dx, 40 + dy), v.pixel_gba(40 + dx, 20 + dy),
                     "live vs fixed digit differ at (#{dx}, #{dy}) — wrong digit width in the loop?"
      end
    end
  end
end
