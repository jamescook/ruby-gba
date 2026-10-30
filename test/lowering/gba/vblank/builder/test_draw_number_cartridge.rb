# frozen_string_literal: true

require "test_helper"

# draw_number on the Advance's cartridge: the runtime digits read back in the emulator, and the
# ARM the lowering emits for one run-time digit. What every run draws is in
# test/all/vblank/builder/test_draw_number.rb.
class TestDrawNumberCartridge < Minitest::Test
  Build = VBlank::IR::Build

  W = Builder::Text::GLYPH_WIDTH # 6px per digit column

  # ---- the runtime digits land on real hardware ----

  private def hw_program
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      var :score, 42
      draw_number :score, 40, 20, :white, digits: 4 # live path
      draw_number 42, 40, 40, :white, digits: 4     # the same number, folded to glyphs
    end
    builder.finalize_program
    builder.program
  end

  def test_live_number_matches_the_literal_on_hardware
    rom = ROM.assemble(GBA.new.lower(hw_program), title: "DRAWNUM", code: "BDNM", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 4)

    # The live digit extraction must land the same pixels as the folded literal.
    (0...(4 * W)).each do |dx|
      (0...7).each do |dy|
        assert_equal v.pixel_gba(40 + dx, 20 + dy), v.pixel_gba(40 + dx, 40 + dy),
                     "hardware: live vs literal differ at column offset #{dx}, row #{dy}"
      end
    end
  end

  # draw_digit is one node whose value is only known at run time. For a normal
  # on-screen column in direct color, the GBA backend renders it data-driven: it
  # embeds the ten digit glyphs once as ROM data and stamps the chosen one with a
  # small loop, instead of baking every pixel of all ten digits into the code.
  def test_draw_digit_renders_from_an_embedded_glyph_table
    code = GBA.new.lower(digit_program_at(8, 8))

    # The chosen glyph is looked up from embedded data, so the font's row bytes
    # appear verbatim in the ROM (here, the default font's "0" glyph).
    zero_glyph = VBlank::Graphics::Font::DEFAULT_GLYPHS["0"].pack("C*")
    assert_includes code, zero_glyph, "the digit glyphs should be embedded as ROM data"

    # And it's a fraction of the hand-written ten-way fan-out it replaces.
    fan_out = GBA.new.lower(digit_fan_out_at(8, 8))
    assert_operator code.bytesize, :<, fan_out.bytesize / 3,
                    "data-driven digit rendering should be far smaller than the fan-out"
  end

  # A column that would cross a screen edge can't skip per-pixel clipping, so the
  # backend falls back to the ten-way per-digit fan-out (each guarded draw_text
  # clips as it draws). Pin that fallback: off-screen, the node matches the fan-out
  # written out by hand.
  def test_draw_digit_off_screen_falls_back_to_the_fan_out
    assert_equal GBA.new.lower(digit_fan_out_at(8, -3)),
                 GBA.new.lower(digit_program_at(8, -3)) # pushed off the top edge
  end

  # One draw_digit node at (x, y), reading a run-time variable.
  private def digit_program_at(x, y)
    Build.program(
      Build.screen(:bitmap), Build.set(:d, 0),
      Build.loop_(Build.wait_vblank, Build.draw_digit(Build.var_ref(:d), x, y, :white), Build.halt),
    )
  end

  # The same drawing spelled out as the ten-way fan-out the backend falls back to.
  private def digit_fan_out_at(x, y)
    Build.program(
      Build.screen(:bitmap), Build.set(:d, 0),
      Build.loop_(Build.wait_vblank,
                  *(0..9).map do |k|
                    Build.if_(Build.binop(:==, Build.var_ref(:d), Build.int(k)),
                              Build.draw_text(k.to_s, x, y, :white))
                  end,
                  Build.halt),
    )
  end
end
