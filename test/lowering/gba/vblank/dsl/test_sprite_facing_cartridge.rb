# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_sprite_facing"

# A sprite's faced pose on the Advance's cartridge, read back in the emulator. What facing does
# on every run is in test/all/vblank/dsl/test_sprite_facing.rb.
class TestSpriteFacingCartridge < Minitest::Test
  include SpriteFacingGames

  def test_the_faced_pose_renders_on_the_console
    prog = faceted_program(frames: 6) { |guy| after(2) { guy.face :left } }
    rom = ROM.assemble(GBA.new.lower(prog), title: "FACING", code: "BFAC", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 7)
    assert v.red?(50, 50), "the left (red) pose should show on hardware — got #{v.pixel_gba(50, 50).to_s(16)}"
    refute v.green?(50, 50), "the right pose should have been restored"
  end
end
