# frozen_string_literal: true

require "test_helper"
require "stringio"

# STOPPING A RUNNING CARTRIDGE AT A ROUTINE AND READING THE PROCESSOR THERE — for somebody
# debugging what the lowering emitted, where the question is what a register held at an
# instruction rather than what came out on screen. The routine is named the way the program
# named it; where it landed is the build's business.
class TestVerifierRegisters < Minitest::Test
  def counting_rom
    RubyGBA.build("REGS", code: "BREG", maker: "01", validate: false, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      count = var :count, 0
      func(:count_up) { count.add! 1 }
      game_loop { call :count_up }
    end
  end

  def test_a_run_stops_at_the_first_instruction_of_a_named_routine
    rom = counting_rom
    v = assert_emulator_loads_rom(rom, frames: 2)
    v.run_until(:count_up)

    assert_equal rom.built.routines.fetch(:count_up).begin, v.registers[:pc]
    assert_includes rom.built.routines.fetch(RubyGBA::Cartridge::BuildRecord::FRAME_ROUTINE), v.registers[:r14],
                    "the routine was called from the game loop, so that is where it returns to"
  end

  def test_a_routine_the_rom_does_not_have_is_a_friendly_error_naming_the_ones_it_does
    v = assert_emulator_loads_rom(counting_rom, frames: 1)
    err = assert_raises(ArgumentError) { v.run_until(:count_down) }
    assert_match(/count_down/, err.message)
    assert_match(/count_up/, err.message)
  end
end
