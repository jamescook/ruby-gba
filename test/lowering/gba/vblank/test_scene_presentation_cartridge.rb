# frozen_string_literal: true

require "test_helper"
require "all/vblank/test_scene_presentation"

# Scene-owned presentation on the Advance's own cartridge: only the active scene's sprite shows,
# read off its screen in the emulator. What every run shows is in
# test/all/vblank/test_scene_presentation.rb, which keeps the game both files play in
# ScenePresentationGames.
class TestScenePresentationCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include ScenePresentationGames

  # The same scene-gated presentation renders on the console: the red block on the title
  # scene, the blue block after START — proof the GBA lowering honors the scene gate for
  # free (it rides the object's existing per-frame `active` value).
  def test_it_renders_each_scene_on_the_console
    rom = assemble_rom(two_scene_program, name: "SCN")

    title = assert_emulator_loads_rom(rom, frames: 4) # no input: :playing
    assert title.pixel_is?(43, 43, :red), "playing block, got 0x#{format('%04X', title.pixel_gba(43, 43))}"
    refute title.pixel_is?(103, 103, :blue), "over block should be hidden on :playing"

    switched = assert_emulator_loads_rom(rom, frames: 6, keys: KEY_START)
    assert switched.pixel_is?(103, 103, :blue), "over block, got 0x#{format('%04X', switched.pixel_gba(103, 103))}"
  end
end
