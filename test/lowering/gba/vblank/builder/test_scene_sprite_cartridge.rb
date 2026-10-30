# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_scene_sprite"

# A painted-screen sprite declared ABOVE the loop, while a tiled scene is up, on the Advance's
# own cartridge: a tiled screen keeps its tile pictures in the same video memory a painted screen
# keeps its pixels in, so a sprite painted then would write into the tiles. That memory is read
# in the emulator here. What every run's picture shows is in
# test/all/vblank/builder/test_scene_sprite.rb, which keeps the game both files play in
# SceneSpriteGames.
class TestSceneSpriteCartridge < Minitest::Test
  include SceneSpriteGames

  VIDEO_MEMORY = 0x0600_0000
  RED_PIXEL = 0x001F

  # The first row of a sprite at the top-left corner, as the console's video memory holds it
  # after +frames+: eight pixels on a painted screen, and on a tiled one the start of the
  # tile pictures, which a sprite painted there would write over.
  private def top_left_of_video_memory(prog, frames)
    v = assert_emulator_loads_rom(ROM.assemble(GBA.new.lower(prog), title: "SCNMEM"), frames: frames)
    Array.new(SIDE) { |pixel| v.mem16(VIDEO_MEMORY + (pixel * 2)) }
  end

  def test_a_sprite_declared_above_the_loop_stays_off_a_tiled_scene
    refute_equal [RED_PIXEL] * SIDE, top_left_of_video_memory(shared_sprite_program, 9),
                 "the sprite was painted into the memory the tiled scene keeps its tiles in"
  end

  # `show` paints a sprite on the spot, and the tiled scene is up when this one is shown.
  def test_a_sprite_shown_while_a_tiled_scene_is_up_waits_for_a_painted_one
    prog = shared_sprite_program(shown: false) { |shared, step| (step == 5).then { shared.show } }

    refute_equal [RED_PIXEL] * SIDE, top_left_of_video_memory(prog, 9), "shown, it was painted into the tiles"
  end
end
