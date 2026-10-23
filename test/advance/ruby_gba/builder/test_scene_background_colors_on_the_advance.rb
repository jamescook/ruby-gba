# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test_scene_background_colors.rb whose games show two backgrounds at once, which a
# Game Boy Color's hardware cannot do, so they play on the Advance's runs alone.
class TestSceneBackgroundColorsOnTheAdvance < Minitest::Test
  include Differential

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # Backgrounds every scene shows that walk between areas, beside a scene with a background of
  # its own: the area's colours and the scene's own both stay right as the ground walks into
  # the second area and the scene takes over.
  private def walking_everywhere_beside_a_scene
    program do
      screen :tiled
      image(:shrine_floor, "#" => :red, "." => :blue) { (["#.#.#.#."] * 8).join("\n") }
      image(:clearing_grass, "#" => :green, "." => :yellow) { (["#..##..#"] * 8).join("\n") }
      image(:sign, "#" => :white, "." => :transparent) { (["##....##"] * 8).join("\n") }
      tiles :shrine, "#" => :shrine_floor
      tiles :clearing, "#" => :clearing_grass
      tiles :signs, "#" => :sign
      grid = (0...20).map { "#" * 30 }
      ground = background :ground, tiles: { shrine: :shrine, clearing: :clearing },
                                   map: { shrine: { hall: grid }, clearing: { glade: grid } }
      var :mode, 0
      pass = var :pass, 0
      room = var :room, 0
      scene(:plain) { nil }
      scene(:signed) { background :board, tiles: :signs, map: ["#" * 30] * 4 }
      game_loop do
        pass.add! 1
        (pass == 3).then { room.set! 1 }
        (pass == 5).then { set! :mode, 1 }
        ground.show_map room
        case_var(:mode) do
          when_val 0, :plain
          when_val 1, :signed
        end
      end
    end
  end

  def test_backgrounds_every_scene_shows_keep_walking_beside_a_scenes_own
    [4, 6, 8].each { |frames| assert_backends_agree(walking_everywhere_beside_a_scene, frames: frames, name: "SBGW") }
  end
end
