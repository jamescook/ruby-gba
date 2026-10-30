# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_layers"

# Layers on the Advance's own cartridge: the picture its console shows for a stack of layers,
# read in the emulator, and a layered game built into a cartridge that passes the cartridge's
# checks. Which layer each declaration ends up in, and what every run draws for it, is in
# test/all/vblank/builder/test_layers.rb, which keeps the game both files play in LayersGames.
class TestLayersCartridge < Minitest::Test
  include LayersGames

  # ...and the console draws what the interpreter says.
  def test_the_console_shows_the_front_layer_too
    rom = assemble_rom(two_reversed_sprites(:bitmap), name: "STACK")
    v = assert_emulator_loads_rom(rom, frames: 6)

    assert v.green?(OVERLAP[0] + 3, OVERLAP[1] + 3),
           "console showed #{format('0x%04x', v.pixel_gba(OVERLAP[0] + 3, OVERLAP[1] + 3))}"
  end

  # --- it survives the whole build ---

  def test_a_layered_game_builds_a_rom
    rom = VBlank.build("LAYERS", console: :gba, code: "BLYR", maker: "01") do
      screen :tiled
      layers :scenery, :actors
      image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :terrain, "." => :grass

      layer(:scenery) { background :world, tiles: :terrain, map: (0...20).map { "." * 30 } }
      hero = layer(:actors) { sprite :guy, at: [100, 60] }
      game_loop { hero.move :right, by: 1 }
    end

    assert VBlank::Cartridge::ROMValidator.check(rom).ok?
  end
end
