# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_repeat"

# repeat(n) on the Advance's cartridge, its marks read in the emulator. What the loop does on
# every run is in test/all/vblank/builder/test_repeat.rb.
class TestRepeatCartridge < Minitest::Test
  include RepeatGames

  def test_runs_on_hardware
    rom = VBlank::Cartridge::ROM.assemble(
      VBlank::IR::Backends::GBA.new.lower(marching_program(4)),
      title: "REPEAT", code: "BRPT", maker: "01",
    )
    v = assert_emulator_loads_rom(rom)
    assert v.green?(0, 40),  "first mark"
    assert v.green?(12, 40), "last mark (index 3)"
    assert v.black?(16, 40), "nothing past the last index"
  end
end
