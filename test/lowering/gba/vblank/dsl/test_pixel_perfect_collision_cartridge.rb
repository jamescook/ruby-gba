# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_pixel_perfect_collision"

# Per-pixel sprite collision on the Advance's own cartridge: the console agrees the
# boxes-overlap-but-pixels-don't case is a miss, read off its screen in the emulator. What every
# run plays is in test/all/vblank/dsl/test_pixel_perfect_collision.rb, which keeps the shape both
# files draw in PixelPerfectCollisionGames.
class TestPixelPerfectCollisionCartridge < Minitest::Test
  include PixelPerfectCollisionGames

  # --- hardware: the console agrees the boxes-overlap-but-pixels-don't case is a miss ---

  private def rom_for(hitbox)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      image(:corners, "." => :transparent, "#" => :white) { CORNERS }
      a  = sprite :corners, at: [100, 20], hitbox: hitbox
      bb = sprite :corners, at: [103, 23], hitbox: hitbox
      game_loop do
        wait_vblank
        a.overlaps?(bb).then { fill_rect 4, 100, 4, 4, :red } # a hit marker away from the shapes
        halt
      end
    end
    b.finalize_program
    ROM.assemble(GBA.new.lower(b.program), title: "PIXPERF", code: "BPPC", maker: "01")
  end

  def test_the_console_sees_no_hit_by_default_but_a_hit_with_a_box
    miss = assert_emulator_loads_rom(rom_for(nil), frames: 3)
    refute miss.red?(5, 101), "per-pixel: the drawn pixels don't meet, so no marker"
    hit = assert_emulator_loads_rom(rom_for(:full), frames: 3)
    assert hit.red?(5, 101), "hitbox: :full: the boxes overlap, so the marker shows"
  end
end
