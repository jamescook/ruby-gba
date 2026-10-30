# frozen_string_literal: true

require "test_helper"
require "console/gba/examples/test_sprite_mover_example"

# The sprite_mover example as the Advance's cartridge: built, and the heart rendering, steering
# and keeping its stack in the emulator. What it does on every run that plays the Advance's
# games is in test/console/gba/examples/test_sprite_mover_example.rb.
class TestSpriteMoverExampleCartridge < Minitest::Test
  include SpriteMoverPlaces

  def test_it_builds_a_rom
    assert SpriteMover.build_rom.size.positive?
  end

  # The same thing the console draws, since this is the bug's whole point.
  def test_the_stack_holds_on_hardware
    rom = ROM.assemble(GBA.new.lower(SpriteMover.program), title: "SPRITEMV", code: "BSPM", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: ON_A_POST + 2, keys: KEY_LEFT)

    assert v.pixel_is?(PLACES[:left_post][0] + 1, POST_ROW, :red),
           "on hardware the heart did not cover the :backdrop post — got " \
           "#{format('0x%04x', v.pixel_gba(PLACES[:left_post][0] + 1, POST_ROW))}"
  end

  def test_it_renders_and_steers_on_hardware
    rom = ROM.assemble(GBA.new.lower(SpriteMover.program), title: "SPRITEMV", code: "BSPM", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 10, keys: KEY_LEFT)
    # after sliding left, the heart's start column is field-blue again (no trail)
    assert v.pixel_is?(START[0] + 2, START[1] + 2, FIELD),
           "the start cell wasn't restored on hardware — got #{v.pixel_gba(START[0] + 2, START[1] + 2).to_s(16)}"
    # and the heart (red) is somewhere to the left of where it began
    moved = (10...START[0]).any? { |x| v.pixel_is?(x, START[1] + 2, :red) }
    assert moved, "the heart isn't found to the left on hardware"
  end
end
