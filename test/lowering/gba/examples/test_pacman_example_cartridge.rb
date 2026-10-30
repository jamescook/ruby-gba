# frozen_string_literal: true

require "test_helper"

require "stringio"
require VBlank.root.join("examples/pacman").to_s

# The Pac-Man example (examples/pacman.rb) as the Advance's cartridge: built, and read back in
# the emulator. What the game does on every run is in test/all/examples/test_pacman_example.rb.
class TestPacmanExampleCartridge < Minitest::Test
  include VBlank::Console::Hardware

  START_X, START_Y = Pacman::START

  def test_it_builds_a_rom
    assert_operator Pacman.build_rom(err: StringIO.new).size, :>, 0, "the built ROM should be non-empty"
  end

  def test_it_renders_and_steers_on_hardware
    rom = ROM.assemble(GBA.new.lower(Pacman.program), title: "PACMAN", code: "BPAC", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 10, keys: KEY_LEFT)
    moved = (40...START_X).any? { |x| (START_Y...START_Y + Pacman::SIZE).any? { |y| v.pixel_is?(x, y, :yellow) } }
    assert moved, "Pac-Man should be found in yellow left of centre on hardware"
    gx, gy = Pacman::GHOST_START
    ghost_there = (gx...gx + Pacman::SIZE).any? { |x| (gy...gy + Pacman::SIZE).any? { |y| v.red?(x, y) } }
    assert ghost_there, "the ghost should render on hardware"
  end
end
