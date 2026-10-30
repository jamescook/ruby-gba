# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test_sprite_layer_choice.rb whose games show a second background while another is
# showing, and a Game Boy Color's hardware cannot, so they play on the Advance's runs alone.
class TestSpriteLayerChoiceOnTheAdvance < Minitest::Test
  include Differential

  UPPER = 0
  WALKING = 1
  STAIRS = 2

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  private def room(floor)
    program do
      screen :tiled
      image(:floor, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:arch, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 16] * 8).join("\n") }
      tiles :floors, "#" => :floor
      tiles :arches, "#" => :arch
      layers :stairs, :ground, :walking, :scenery, :upper

      layer(:ground) { background :ground_bg, tiles: :floors, map: (0...20).map { "#" * 30 } }
      layer(:scenery) { background :arch_bg, tiles: :arches, map: (0...20).map { ("#" * 13) + (" " * 17) } }
      hero = layer(:upper) { sprite :guy, at: [96, 64] }
      depth = var :floor, floor
      game_loop { hero.put_in_layer %i[upper walking stairs], showing: depth }
    end
  end

  # The interpreter paints the picture itself; the console composites it from a two-bit
  # depth in each sprite's table entry, which this has to write from the number.
  def test_both_backends_draw_the_hero_upstairs
    assert_backends_agree(room(UPPER), frames: 3, name: "LYRUP")
  end

  def test_both_backends_draw_the_hero_on_the_ground_floor
    assert_backends_agree(room(WALKING), frames: 3, name: "LYRWK")
  end

  def test_both_backends_draw_the_hero_on_the_stairs
    assert_backends_agree(room(STAIRS), frames: 3, name: "LYRST")
  end

  # The same room as a scene of its own, beside a title screen that has no backgrounds:
  # the depths are worked out for each screen apart, and the hero's choices with them.
  private def scene_room(floor)
    program do
      screen :tiled
      image(:floor, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:arch, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 16] * 8).join("\n") }
      tiles :floors, "#" => :floor
      tiles :arches, "#" => :arch
      layers :stairs, :ground, :walking, :scenery, :upper
      var :mode, 1
      depth = var :floor, floor

      scene(:title) { layer(:upper) { draw_text "HI", 8, 8, :white } }
      scene(:room) do
        layer(:ground) { background :ground_bg, tiles: :floors, map: (0...20).map { "#" * 30 } }
        layer(:scenery) { background :arch_bg, tiles: :arches, map: (0...20).map { ("#" * 13) + (" " * 17) } }
        hero = layer(:upper) { sprite :guy, at: [96, 64] }
        hero.put_in_layer %i[upper walking stairs], showing: depth
      end
      game_loop do
        case_var(:mode) do
          when_val 0, :title
          when_val 1, :room
        end
      end
    end
  end

  def test_both_backends_draw_a_scenes_hero_on_the_stairs
    assert_backends_agree(scene_room(STAIRS), frames: 4, name: "LYRSC")
  end

  # A hero declared ONCE, for every room, in a game with a plain room (a floor and nothing
  # over it) and the arched one. The ground floor is one depth from the front in the plain
  # room and two in the arched one, so the console has to be told which room is up.
  private def two_rooms(mode)
    program do
      screen :tiled
      image(:floor, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:arch, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 16] * 8).join("\n") }
      tiles :floors, "#" => :floor
      tiles :arches, "#" => :arch
      layers :stairs, :ground, :walking, :scenery, :upper
      var :mode, mode
      depth = var :floor, WALKING
      hero = layer(:upper) { sprite :guy, at: [96, 64] }

      scene(:plain) do
        layer(:ground) { background :plain_floor, tiles: :floors, map: (0...20).map { "#" * 30 } }
      end
      scene(:room) do
        layer(:ground) { background :ground_bg, tiles: :floors, map: (0...20).map { "#" * 30 } }
        layer(:scenery) { background :arch_bg, tiles: :arches, map: (0...20).map { ("#" * 13) + (" " * 17) } }
      end
      game_loop do
        hero.put_in_layer %i[upper walking stairs], showing: depth
        case_var(:mode) do
          when_val 0, :plain
          when_val 1, :room
        end
      end
    end
  end

  def test_both_backends_put_a_hero_every_room_shows_on_the_plain_rooms_floor
    assert_backends_agree(two_rooms(0), frames: 4, name: "LYRPL")
  end

  def test_both_backends_put_the_same_hero_under_the_arched_rooms_arch
    assert_backends_agree(two_rooms(1), frames: 4, name: "LYRAR")
  end
end
