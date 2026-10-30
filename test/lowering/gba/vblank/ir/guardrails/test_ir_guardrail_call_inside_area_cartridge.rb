# frozen_string_literal: true

require "test_helper"
require "all/vblank/ir/guardrails/test_ir_guardrail_call_inside_area"

# PROOF THAT THE FOOTGUN IS REAL, on the Advance's own cartridge: a routine called from inside an
# area is not clipped by the console, which bakes the clip into the routine's own instructions
# wherever it happens to be lowered. It lowers straight from the IR, bypassing the validation pass
# that now refuses such a program, and reads the screen in the emulator. The check itself is in
# test/all/vblank/ir/guardrails/test_ir_guardrail_call_inside_area.rb, which keeps the game both
# files play in CallInsideAreaGames.
class TestIRGuardrailCallInsideAreaCartridge < Minitest::Test
  include CallInsideAreaGames

  def test_the_console_does_not_clip_a_routine_called_from_inside_an_area
    rom = ROM.assemble(GBA.new.lower(game_with_call_that_draws), title: "CIAR", code: "BCIA", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3)
    assert v.red?(120, 50),
           "the console draws the routine's fill everywhere — the bug this check exists for"
  end
end
