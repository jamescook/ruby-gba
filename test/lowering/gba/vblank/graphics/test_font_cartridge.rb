# frozen_string_literal: true

require "test_helper"

# Text drawn in a font, built into the Advance's cartridge and loaded in the emulator. The font's
# glyphs, metrics and registry are in test/all/vblank/graphics/test_font.rb.
class TestFontCartridge < Minitest::Test
  # ---- draw_text through the builder ----

  private def build(validate: false, &block)
    VBlank.build("FONTEST", console: :gba, code: "BFNT", maker: "01", validate: validate, out: nil, err: nil, &block)
  end

  def test_draw_text_builds_and_emits_pixels
    rom = build do
      screen :bitmap
      draw_text "I", 0, 0, :white
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_draw_text_runs_in_mgba
    rom = build do
      screen :bitmap
      clear_screen :black
      draw_text "PONG", 96, 40, :white
      draw_text "PRESS START", 64, 100, :gray
      halt
    end
    assert_emulator_loads_rom(rom, frames: 5)
  end
end
