# frozen_string_literal: true

require "test_helper"

# The hero game, shared with the Advance's cartridge's tests
# (test/lowering/gba/vblank/dsl/test_hardware_sprite_cartridge.rb).
module HardwareSpriteGames
  include SharedConstants

  # A blue floor of 8x8 tiles filling the screen, and a red 8x8 hero sprite that
  # slides right by +step+ while :right is held, halting after +frames+ steps so its
  # resting place is deterministic. The hero is drawn each frame by the framework —
  # there's no draw call in the loop, exactly like the software sprite.
  private def hero_program(frames:, step: 8, start: [40, 40])
    start_x, start_y = start
    floor_map = Array.new(20, "#" * 30) # 30x20 tiles = the whole 240x160 screen
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :blue) { SOLID_TILE }
      image(:hero,  "#" => :red)  { SOLID_TILE }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: floor_map
      hero = sprite :hero, at: [start_x, start_y]
      f = var :f, 0
      game_loop do
        wait_vblank
        held(:right).then { hero.x.add! step }
        f.add! 1
        (f >= frames).then { halt }
      end
    end
    builder.finalize_program
    builder.program
  end
end

# Hardware sprites: on a `screen :tiled`, `sprite :hero, at:` gives a sprite the
# console composites over the tiled background — the SAME handle you get in bitmap
# mode (x / y / move), so the game code doesn't change. These assert the observable
# result: the right sprite over the background at its position, no trail when it
# moves, and the friendly guardrails — on the interpreter oracle and on real
# hardware. The dev never touches OAM, tile indices, or object memory.
#
# The same game on the Advance's cartridge, read in the emulator, is in
# test/lowering/gba/vblank/dsl/test_hardware_sprite_cartridge.rb.
class TestHardwareSprite < Minitest::Test
  include HardwareSpriteGames

  # --- it renders, composited over the background ---

  def test_the_sprite_renders_over_the_tiled_background
    # No input held, so the hero stays at (40, 40): its 8x8 body covers 40..47.
    screen = game_player.run(hero_program(frames: 2)).screen
    assert_equal Color.resolve(:red),  screen.pixel(44, 44), "the hero renders over the background"
    assert_equal Color.resolve(:blue), screen.pixel(8, 8),   "the floor shows where the hero isn't"
  end

  # --- it moves, and the console redraws the whole scene so no trail is left ---

  # Holding right for 3 frames (step 8): drawn at 40, 48, 56 on successive frames,
  # so it comes to rest with its body over 56..63 while the start column shows floor.
  def test_a_moving_sprite_leaves_no_trail
    # The third pass's place, as far behind as the framework draws (Testing#framework_drawing_lag).
    screen = game_player.input_each_frame { [:right] }.run(hero_program(frames: 2 + framework_drawing_lag)).screen
    assert_equal Color.resolve(:red),  screen.pixel(60, 44), "the hero is at its new spot"
    assert_equal Color.resolve(:blue), screen.pixel(44, 44), "the start column shows floor again — no trail"
  end

  # --- friendly guardrails ---
  # (facing/poses now work in tiled mode — see test_hardware_sprite_facing.rb)

  # A picture that is not a whole number of tiles cannot be a sprite at all — a size
  # bigger than the console's largest object is fine (it is drawn as several), but a
  # ragged one has pixels no tile holds.
  def test_a_sprite_that_is_not_whole_tiles_is_a_friendly_error
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:blob, "#" => :red) { "#####\n#####\n#####" } # 5x3 — not whole tiles
      sprite :blob, at: [0, 0]
    end
    b.finalize_program
    err = assert_raises(GBA::LoweringError) { GBA.new.lower(b.program) }
    assert_match(/8x8 tiles/, err.message)
    assert_match(/:blob is 5x3/, err.message)
  end
end
