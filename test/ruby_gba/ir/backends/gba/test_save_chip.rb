# frozen_string_literal: true

require "test_helper"

# WHICH SAVE CHIP A CARTRIDGE WRITES TO, picked from the save memory the program says it has.
# The battery-backed 32K is the only one written yet; flash is refused.
class TestSaveChip < Minitest::Test
  private def program(save_memory)
    builder = Builder.new(save_memory: save_memory)
    builder.instance_eval do
      screen :bitmap
      save_var :best, 0
      game_loop {}
    end
    builder.finalize_program
    builder.program
  end

  # A program built by hand rather than as a game skips the game's own refusal, so the step that
  # makes the cartridge refuses flash too.
  def test_a_flash_program_built_by_hand_is_refused_on_its_way_to_a_cartridge
    error = assert_raises(RubyGBA::IR::Backends::GBA::LoweringError) { assemble_rom(program(64)) }

    assert_match(/64K/, error.message)
    assert_match(/not available yet/, error.message)
  end

  def test_a_32k_cartridge_carries_the_marker_that_maps_battery_memory
    assert_includes assemble_rom(program(32)).buffer, "SRAM_V123"
  end
end
