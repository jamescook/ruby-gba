# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_hitbox"

# A SPRITE'S COLLISION BOX ON THE ADVANCE'S CARTRIDGE, seen in the emulator. Which boxes collide
# on every run is in test/all/vblank/dsl/test_hitbox.rb.
class TestHitboxCartridge < Minitest::Test
  include HitboxGames

  # --- hardware: visible-box collision fires on the console ---

  def test_visible_collision_on_the_console
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:dot, "." => :transparent, "#" => :white) { DOT_ART }
      a = sprite :dot, at: [100, 60]
      hit_me = sprite :dot, at: [103, 60] # its visible block meets a's, so they collide
      game_loop do
        wait_vblank
        a.overlaps?(hit_me).then { hit_me.move_to 0, 0 } # on a real hit, snap it to the corner
      end
    end
    b.finalize_program
    rom = ROM.assemble(GBA.new.lower(b.program), title: "HITBOX", code: "BHIT", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 8)
    # It collided and snapped to (0,0), so its visible block (offset 2,2) is white there.
    assert v.white?(3, 3), "the sprite snapped to the corner on a visible-pixel hit, got 0x#{format('%04X', v.pixel_gba(3, 3))}"
  end
end
