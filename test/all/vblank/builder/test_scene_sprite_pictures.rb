# frozen_string_literal: true

require "test_helper"
require "scene_sprite_pictures"

# Scenes whose sprite pictures together are more than a console holds, and few enough one scene at
# a time (test/scene_sprite_pictures.rb). Every lowering shows each scene's sprite in each of its
# pictures, as the interpreter does, through every handover, the first scene's coming back last.
class TestSceneSpritePictures < Minitest::Test
  private def program(**declared)
    b = Builder.new
    SceneSpritePictures.declare(b, **declared)
    b.finalize_program
    b.program
  end

  # Frames since power-on at the last pass of +frames+, for the game with +poses+ pictures a scene.
  private def frames_seen(poses, frames, backgrounds: nil)
    game_player.run(program(poses: poses, clock: true, backgrounds: backgrounds), frames: frames)[:seen]
  end

  def test_bringing_pictures_in_beside_backgrounds_costs_no_frame
    frames = SceneSpritePictures::PASSES_A_SCENE * (SceneSpritePictures::SCENES.length + 1)

    assert_equal frames_seen(2, frames, backgrounds: 40), frames_seen(SceneSpritePictures::POSES, frames, backgrounds: 40)
  end

  # Bringing a scene's pictures in is part of its taking over, and costs the game no frame: the
  # clock reads the same after three handovers as for a game whose pictures all fit at once.
  def test_bringing_pictures_in_costs_no_frame
    frames = SceneSpritePictures::PASSES_A_SCENE * (SceneSpritePictures::SCENES.length + 1)

    assert_equal frames_seen(2, frames), frames_seen(SceneSpritePictures::POSES, frames)
  end

  def test_each_scene_shows_its_own_pictures_through_every_handover
    frames = SceneSpritePictures::PASSES_A_SCENE * (SceneSpritePictures::SCENES.length + 1)
    i = game_player.run(program, frames: frames)

    assert_equal Color.resolve(:red), i.screen.pixel(8, 9), "the sprite every scene shows"
    assert_equal Color.resolve(:white), i.screen.pixel(40, 41), "the first scene's own, back"
  end
end
