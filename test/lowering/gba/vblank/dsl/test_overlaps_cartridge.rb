# frozen_string_literal: true

require "test_helper"

# a.overlaps?(b) on the Advance's cartridge, read back in the emulator. What every run is held
# to is in test/all/vblank/dsl/test_overlaps.rb.
class TestOverlapsCartridge < Minitest::Test
  A = [10, 10, 8, 8].freeze # spans x 10..18, y 10..18, as in the shared file

  # The same test, run on the console: a green marker is painted only while the two
  # boxes overlap. Two static cases — one overlapping, one apart — prove the verb
  # lowers to hardware, not just the interpreter.
  private def rom_for(a_dims, b_dims)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      box(*a_dims).overlaps?(box(*b_dims)).then { fill_rect 100, 80, 4, 4, :green }
      halt
    end
    b.finalize_program
    ROM.assemble(GBA.new.lower(b.program), title: "OVERLAP", code: "BOVL", maker: "01")
  end

  def test_overlap_lowers_to_hardware
    v = assert_emulator_loads_rom(rom_for(A, [14, 14, 8, 8]), frames: 2)
    assert v.green?(101, 81), "overlapping boxes light the marker on hardware"
  end

  def test_no_overlap_draws_nothing_on_hardware
    v = assert_emulator_loads_rom(rom_for(A, [40, 40, 8, 8]), frames: 2)
    assert v.black?(101, 81), "separated boxes leave the screen clear on hardware"
  end
end
