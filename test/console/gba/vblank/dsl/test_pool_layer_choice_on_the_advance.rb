# frozen_string_literal: true

require "test_helper"
require "differential"

# A POOL WHOSE THINGS CHANGE WHICH LAYER THEY ARE IN while the game runs: `put_in_layer` told to
# the pool, which moves every one of its things at once, as a sprite told it moves.
#
# The room is test_sprite_layer_choice_on_the_advance.rb's: a white floor at the back and a blue
# arch in front of it, covering the left half of the screen. Two red guards of one pool stand
# across the arch's edge, one above the other, so each has a pixel under the arch and one over
# bare floor. A Game Boy Color shows one background at a time, so this plays on the Advance's
# runs alone.
class TestPoolLayerChoiceOnTheAdvance < Minitest::Test
  include Differential

  RED = VBlank::Graphics::Color.resolve(:red)
  WHITE = VBlank::Graphics::Color.resolve(:white)
  BLUE = VBlank::Graphics::Color.resolve(:blue)

  # Each guard's two pixels: under the arch, then over the floor.
  GUARDS = [[[100, 66], [108, 66]], [[100, 98], [108, 98]]].freeze

  UPPER = 0
  WALKING = 1
  STAIRS = 2

  private def pixels(prog)
    screen = game_player.run(prog, max_steps: 400_000, frames: 3).screen
    GUARDS.map { |under, over| [screen.pixel(*under), screen.pixel(*over)] }
  end

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
      guards = layer(:upper) { pool :guards, x: 0, y: 0, capacity: 4, image: :guy }
      guards.spawn x: 96, y: 64
      guards.spawn x: 96, y: 96
      depth = var :floor, floor
      game_loop { guards.put_in_layer %i[upper walking stairs], showing: depth }
    end
  end

  def test_upstairs_every_guard_is_in_front_of_both_layers
    assert_equal [[RED, RED]] * 2, pixels(room(UPPER))
  end

  def test_on_the_ground_floor_the_arch_covers_every_guard
    assert_equal [[BLUE, RED]] * 2, pixels(room(WALKING))
  end

  def test_on_the_stairs_every_guard_is_behind_both_layers
    assert_equal [[BLUE, WHITE]] * 2, pixels(room(STAIRS))
  end

  def test_a_number_past_the_list_keeps_the_layer_the_pool_was_declared_in
    assert_equal [[RED, RED]] * 2, pixels(room(7))
  end

  def test_both_backends_draw_the_guards_on_the_ground_floor
    assert_backends_agree(room(WALKING), frames: 3, name: "PLYWK")
  end

  def test_both_backends_draw_the_guards_on_the_stairs
    assert_backends_agree(room(STAIRS), frames: 3, name: "PLYST")
  end

  # One layer said outright, rather than picked by a number.
  def test_one_layer_said_outright_moves_every_guard
    prog = program do
      screen :tiled
      image(:floor, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:arch, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 16] * 8).join("\n") }
      tiles :floors, "#" => :floor
      tiles :arches, "#" => :arch
      layers :ground, :walking, :scenery, :upper

      layer(:ground) { background :ground_bg, tiles: :floors, map: (0...20).map { "#" * 30 } }
      layer(:scenery) { background :arch_bg, tiles: :arches, map: (0...20).map { ("#" * 13) + (" " * 17) } }
      guards = layer(:upper) { pool :guards, x: 0, y: 0, capacity: 4, image: :guy }
      guards.spawn x: 96, y: 64
      guards.spawn x: 96, y: 96
      game_loop { guards.put_in_layer :walking }
    end

    assert_equal [[BLUE, RED]] * 2, pixels(prog)
  end

  # Rooms of both kinds in one cartridge: one pool declared for every scene, and two scenes, a
  # field whose arch the guards walk under and a house whose top layer is furniture they stand
  # in front of. Each scene moves the pool as it takes over.
  private def two_rooms(mode)
    program do
      screen :tiled
      image(:floor, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:arch, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 16] * 8).join("\n") }
      tiles :floors, "#" => :floor
      tiles :arches, "#" => :arch
      layers :ground, :walking, :scenery, :upper
      var :mode, mode
      guards = layer(:upper) { pool :guards, x: 0, y: 0, capacity: 4, image: :guy }
      guards.spawn x: 96, y: 64
      guards.spawn x: 96, y: 96

      scene(:field) do
        layer(:ground) { background :ground_bg, tiles: :floors, map: (0...20).map { "#" * 30 } }
        layer(:scenery) { background :arch_bg, tiles: :arches, map: (0...20).map { ("#" * 13) + (" " * 17) } }
        guards.put_in_layer :walking
      end
      scene(:house) do
        layer(:ground) { background :ground_bg, tiles: :floors, map: (0...20).map { "#" * 30 } }
        layer(:scenery) { background :arch_bg, tiles: :arches, map: (0...20).map { ("#" * 13) + (" " * 17) } }
        guards.put_in_layer :upper
      end
      game_loop do
        case_var(:mode) do
          when_val 0, :field
          when_val 1, :house
        end
      end
    end
  end

  def test_in_the_field_the_guards_walk_under_the_arch
    assert_equal [[BLUE, RED]] * 2, pixels(two_rooms(0))
  end

  def test_in_the_house_the_guards_stand_in_front_of_the_furniture
    assert_equal [[RED, RED]] * 2, pixels(two_rooms(1))
  end

  def test_both_backends_draw_the_guards_in_the_field
    assert_backends_agree(two_rooms(0), frames: 3, name: "PLYFD")
  end
end
