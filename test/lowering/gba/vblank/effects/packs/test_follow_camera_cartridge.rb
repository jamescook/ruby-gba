# frozen_string_literal: true

require "test_helper"
require "all/vblank/effects/packs/test_follow_camera"

# The follow camera on the Advance's cartridge: the world scrolls under a planted character,
# read back in the emulator. What it does on every run is in
# test/all/vblank/effects/packs/test_follow_camera.rb.
class TestFollowCameraCartridge < Minitest::Test
  include FollowCameraGames

  # --- and on the console ---

  def test_the_world_scrolls_under_a_planted_character_on_the_console
    prog = walking_game { |hero| held(:right).then { hero.move :right, by: 2 } }
    rom = VBlank::Cartridge::ROM.assemble(GBA.new.lower(prog), title: "FOLLOW", code: "BFLW", maker: "01")

    at_rest = assert_emulator_loads_rom(rom, frames: 4)
    walked = assert_emulator_loads_rom(rom, frames: 30, keys: VBlank::Console::Hardware::KEY_RIGHT)

    assert at_rest.red?(120, 80), "the character renders in the middle of the screen"
    assert walked.red?(120, 80), "and is still there after walking — the console moved the world"
  end
end
