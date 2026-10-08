# frozen_string_literal: true

require "test_helper"
require "differential"

# A SPRITE THAT CHANGES WHICH LAYER IT IS IN while the game runs.
#
# The room is two backgrounds: a white floor at the back and a blue arch in front of
# it, the arch covering the left half of the screen and see-through over the right. The
# hero is red, and stands across the arch's edge, so one pixel of him is under the arch
# and one is over bare floor. Where he is drawn at each of the three depths a room like
# this has is the whole test:
#
#   * upstairs, in front of both, he is red at both pixels;
#   * on the ground floor, between the two, the arch covers him and the floor does not;
#   * on the stairs, behind both, he shows nowhere, since the floor is solid.
class TestSpriteLayerChoice < Minitest::Test
  include Differential

  RED = RubyGBA::Graphics::Color.resolve(:red)
  WHITE = RubyGBA::Graphics::Color.resolve(:white)
  BLUE = RubyGBA::Graphics::Color.resolve(:blue)

  UNDER_ARCH = [100, 66].freeze
  OVER_FLOOR = [108, 66].freeze

  UPPER = 0
  WALKING = 1
  STAIRS = 2

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  def room(floor)
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

  def pixels(prog)
    screen = Reference.new.run(prog, max_steps: 400_000, frames: 3).screen
    [screen.pixel(*UNDER_ARCH), screen.pixel(*OVER_FLOOR)]
  end

  def test_upstairs_the_hero_is_in_front_of_both_layers
    assert_equal [RED, RED], pixels(room(UPPER))
  end

  def test_on_the_ground_floor_the_arch_covers_the_hero
    assert_equal [BLUE, RED], pixels(room(WALKING))
  end

  def test_on_the_stairs_the_hero_is_behind_both_layers
    assert_equal [BLUE, WHITE], pixels(room(STAIRS))
  end

  def test_a_number_past_the_list_keeps_the_layer_the_hero_was_declared_in
    assert_equal [RED, RED], pixels(room(7))
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
  def scene_room(floor)
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

  def test_a_hero_in_a_scene_goes_behind_the_scenes_own_arch
    assert_equal [BLUE, RED], pixels(scene_room(WALKING))
  end

  def test_both_backends_draw_a_scenes_hero_on_the_stairs
    assert_backends_agree(scene_room(STAIRS), frames: 4, name: "LYRSC")
  end

  # A hero declared ONCE, for every room, in a game with a plain room (a floor and nothing
  # over it) and the arched one. The ground floor is one depth from the front in the plain
  # room and two in the arched one, so the console has to be told which room is up.
  def two_rooms(mode)
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

  def test_a_hero_every_room_shows_stands_on_the_plain_rooms_floor
    assert_equal [RED, RED], pixels(two_rooms(0))
  end

  def test_both_backends_put_a_hero_every_room_shows_on_the_plain_rooms_floor
    assert_backends_agree(two_rooms(0), frames: 4, name: "LYRPL")
  end

  def test_both_backends_put_the_same_hero_under_the_arched_rooms_arch
    assert_backends_agree(two_rooms(1), frames: 4, name: "LYRAR")
  end

  # --- what it refuses ---

  def build_error(&block)
    assert_raises(ArgumentError) { program(&block) }
  end

  def test_a_layer_the_stack_does_not_have_is_refused_and_the_stack_is_shown
    error = build_error do
      screen :tiled
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :ground, :upper
      hero = layer(:upper) { sprite :guy, at: [0, 0] }
      game_loop { hero.put_in_layer :stairz }
    end

    assert_match(/no layer of that name/, error.message)
    assert_match(/:ground, :upper/, error.message)
  end

  def test_a_game_with_no_stack_is_told_to_declare_one
    error = build_error do
      screen :tiled
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      hero = sprite :guy, at: [0, 0]
      game_loop { hero.put_in_layer :upper }
    end

    assert_match(/declares no layers/, error.message)
  end

  def test_several_layers_with_nothing_to_pick_between_them_are_refused
    error = build_error do
      screen :tiled
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :ground, :upper
      hero = layer(:upper) { sprite :guy, at: [0, 0] }
      game_loop { hero.put_in_layer %i[ground upper] }
    end

    assert_match(/showing:/, error.message)
  end

  def test_one_layer_with_showing_is_told_to_give_a_list
    error = build_error do
      screen :tiled
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :ground, :upper
      hero = layer(:upper) { sprite :guy, at: [0, 0] }
      floor = var :floor, 0
      game_loop { hero.put_in_layer :ground, showing: floor }
    end

    assert_match(/names one layer/, error.message)
  end

  def test_a_sprite_on_a_bitmap_screen_is_told_it_has_no_layers_to_move_between
    error = build_error do
      screen :bitmap
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :ground, :upper
      hero = layer(:upper) { sprite :guy, at: [0, 0] }
      game_loop { hero.put_in_layer :ground }
    end

    assert_match(/screen :tiled/, error.message)
  end
end
