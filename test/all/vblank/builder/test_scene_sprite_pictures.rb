# frozen_string_literal: true

require "test_helper"
require "scene_sprite_pictures"

# Scenes whose sprite pictures together are more than a console holds, and few enough one scene at
# a time (test/scene_sprite_pictures.rb). Every lowering shows each scene's sprite in each of its
# pictures, as the interpreter does, through every handover, the first scene's coming back last.
class TestSceneSpritePictures < Minitest::Test
  private def program
    b = Builder.new
    SceneSpritePictures.declare(b)
    b.finalize_program
    b.program
  end

  def test_each_scene_shows_its_own_pictures_through_every_handover
    frames = SceneSpritePictures::PASSES_A_SCENE * (SceneSpritePictures::SCENES.length + 1)
    i = game_player.run(program, frames: frames)

    assert_equal Color.resolve(:red), i.screen.pixel(8, 9), "the sprite every scene shows"
    assert_equal Color.resolve(:white), i.screen.pixel(40, 41), "the first scene's own, back"
  end
end
