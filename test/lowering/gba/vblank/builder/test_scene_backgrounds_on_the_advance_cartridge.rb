# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/builder/test_scene_backgrounds_on_the_advance"

# A SCENE WITH NO SCENERY OF ITS OWN, ON THE ADVANCE'S CARTRIDGE, read in the emulator. What it
# shows, asked of every run that plays the Advance, is in
# test/console/gba/vblank/builder/test_scene_backgrounds_on_the_advance.rb.
class TestSceneBackgroundsOnTheAdvanceCartridge < Minitest::Test
  include SceneBackgroundsOnTheAdvanceGames

  private def on_console(prog, name, frames)
    assert_emulator_loads_rom(assemble_rom(prog, name: name), frames: frames).pixel_gba(*MIDDLE)
  end

  # A scene with no scenery of its own takes down the last scene's, on the console too.
  def test_the_console_takes_down_the_last_scenes_scenery
    assert_equal RED, on_console(a_backdrop_then_a_bare_scene, "SCNBG0", SWITCH_AT + 6), "on the Advance's cartridge"
  end
end
