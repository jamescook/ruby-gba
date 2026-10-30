# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_approach"

# `approach` and `clamp` on the Advance's cartridge, the values and the marker read in the
# emulator. What they do on every run is in test/all/vblank/dsl/test_approach.rb.
class TestApproachCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include ApproachGames

  # A FLOOR ABOVE ITS CEILING, which bounds worked out as the game runs can reach. The value
  # is held at the floor and then at the ceiling, so the ceiling wins and the answer is the
  # ceiling wherever the value started — on both runners, for the word that changes the
  # variable and the word that hands back a new number.
  def test_a_floor_above_its_ceiling_gives_the_ceiling_on_both_backends
    names = %i[below between above made]
    backend = GBA.new
    rom = VBlank::Cartridge::ROM.assemble(backend.lower(floor_above_its_ceiling), title: "CLAMPLOHI", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 2, vars: backend.var_addresses)

    assert_equal [10, 10, 10, 10], names.map { |name| v.var(name) }, "the console"
  end

  # ---- both backends agree, on real hardware ----

  def test_marker_homes_in_on_hardware
    machine_code = VBlank::IR::Backends::GBA.new.lower(marker_program(frames: 20))
    rom = VBlank::Cartridge::ROM.assemble(machine_code, title: "APPROACH", code: "BAPP", maker: "01")

    v = assert_emulator_loads_rom(rom, frames: 22)
    assert v.green?(100, 50), "the marker reached the target on hardware"
    assert v.black?(0, 50),   "and left the start column"
  end

  def test_a_run_time_step_and_bound_agree_on_hardware
    early = rom_for(limited_marker_program(frames: 5))
    late = rom_for(limited_marker_program(frames: 20))

    v_early = assert_emulator_loads_rom(early, frames: 7)
    v_late = assert_emulator_loads_rom(late, frames: 22)

    assert v_early.green?(MID_JOURNEY, 50), "the console stepped by the same amount"
    assert v_early.black?(60, 50), "and had not reached the limit yet"
    assert v_late.green?(60, 50), "and it holds at the same limit"
  end

  private def rom_for(program)
    VBlank::Cartridge::ROM.assemble(VBlank::IR::Backends::GBA.new.lower(program),
                                    title: "APPROACH", code: "BAPP", maker: "01")
  end
end
