# frozen_string_literal: true

require "test_helper"
require "all/vblank/ir/guardrails/test_ir_guardrail_bitmap_draw_on_tiled"

# The footgun the BitmapDrawOnTiled guardrail exists for, PROVED on the emulated console
# before any guardrail is involved. It builds the ROM straight from the builder's IR, not
# through VBlank.build, so it bypasses the validation pass and keeps proving the hardware
# behavior now that the guardrail stops such a program from being built. The guardrail's own
# tests are in test/all/vblank/ir/guardrails/test_ir_guardrail_bitmap_draw_on_tiled.rb.
class TestIRGuardrailBitmapDrawOnTiledCartridge < Minitest::Test
  include BitmapDrawOnTiledGames

  # --- Proof that the footgun is real ---

  # The background paints and the fill does not. Both points come back the same
  # blue, so the red rectangle the game draws every frame simply is not there —
  # and the build that produced this ROM said nothing at all.
  def test_the_fill_never_reaches_the_console_but_the_background_does
    rom = ROM.assemble(GBA.new.lower(tiled_game_that_also_fills),
                       title: "GAP", code: "BGAP", maker: "01")

    v = assert_emulator_loads_rom(rom, frames: 6)
    assert v.blue?(20, 20), "the background should show"
    assert v.blue?(120, 80),
           "the middle of the fill_rect should still be background blue — a tiled screen " \
           "never reads the framebuffer, got 0x#{format('%04X', v.pixel_gba(120, 80))}"
    refute v.red?(120, 80), "red at (120, 80) would mean the fill landed after all"
  end
end
