# frozen_string_literal: true

require "test_helper"
require "scene_sprite_pictures"

# A Game Boy Color holds 256 sprite tiles at once. A game whose scenes' sprite pictures between them
# need more still builds, each scene bringing its own pictures in as it takes over, with its own
# background tiles (GBC::Art::Room). What one scene cannot hold, it cannot, and the build says which
# scene. Whether the scenes then show the interpreter's pictures is
# test/all/vblank/builder/test_scene_sprite_pictures.rb, on every lowering.
class TestGBCScenePictures < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  private def color_program(options: VBlank::Cartridge::Options.new(console: :gbc), **declared)
    b = Builder.new(options: options)
    SceneSpritePictures.declare(b, **declared)
    b.finalize_program
    b.program
  end

  # 70 pictures of four tiles: 284 for the forest, with the heart every scene shows.
  def test_one_scene_with_more_sprite_tiles_than_the_color_holds_is_refused_naming_it
    error = assert_raises(GBC::LoweringError) { GBC.new.build(color_program(scenes: %i[forest], poses: 70)) }

    assert_match(/the sprites of the scene :forest need \d+ tiles/, error.message)
    assert_match(/room for 256/, error.message)
  end

  # Where the console draws each sprite piece 8×16, a scene's own tiles start at an even number, as
  # every tall piece's do, and the scenes still show the interpreter's pictures.
  def test_scenes_bring_their_own_tall_pieces_in
    options = VBlank::Cartridge::Options.new(console: :gbc, sprite_piece_size: { gbc: [8, 16] })
    frames = SceneSpritePictures::PASSES_A_SCENE * (SceneSpritePictures::SCENES.length + 1)
    i = game_player.run(color_program(options: options), frames: frames)

    assert_equal Color.resolve(:white), i.screen.pixel(40, 41)
  end
end
