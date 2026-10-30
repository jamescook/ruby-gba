# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_timers"

# The timed-trigger verbs on the Advance's cartridge: the schedule holds on real hardware, read
# back in the emulator. How every(n) and after(n) behave on every run is in
# test/all/vblank/builder/test_timers.rb.
class TestTimersCartridge < Minitest::Test
  include TimersGames

  # ---- hardware: the schedule holds on the console ----

  def test_after_drives_a_marker_on_both_backends
    program = blink_program(frames: 4)
    rom = VBlank::Cartridge::ROM.assemble(VBlank::IR::Backends::GBA.new.lower(program),
                                          title: "TIMERS", code: "BTMR", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 6)
    assert v.red?(103, 83), "console: the after(2) marker is drawn"
  end
end
