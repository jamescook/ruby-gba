# frozen_string_literal: true

require "test_helper"

# A POOL WHOSE THINGS CHANGE WHICH LAYER THEY ARE IN while the game runs (Pool#put_in_layer), in a
# room of one background every console shows: a blue arch over the left half of the screen. Two
# red guards stand across its edge, so each has a pixel under the arch and one over the backdrop.
# Rooms of two backgrounds, and the cartridge read back, are in
# test/console/gba/vblank/dsl/test_pool_layer_choice_on_the_advance.rb.
class TestPoolLayerChoice < Minitest::Test
  RED = VBlank::Graphics::Color.resolve(:red)
  BLUE = VBlank::Graphics::Color.resolve(:blue)

  # Each guard's two pixels: under the arch, then clear of it.
  GUARDS = [[[100, 66], [108, 66]], [[100, 98], [108, 98]]].freeze

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  private def arch(depth)
    program do
      screen :tiled, backdrop: :black
      image(:arch, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 16] * 8).join("\n") }
      tiles :arches, "#" => :arch
      layers :walking, :scenery, :upper
      layer(:scenery) { background :arch_bg, tiles: :arches, map: (0...18).map { ("#" * 13) + (" " * 7) } }
      guards = layer(:upper) { pool :guards, x: 0, y: 0, capacity: 4, image: :guy }
      guards.spawn x: 96, y: 64
      guards.spawn x: 96, y: 96
      floor = var :floor, depth
      game_loop { guards.put_in_layer %i[upper walking], showing: floor }
    end
  end

  private def pixels(prog)
    screen = game_player.run(prog, frames: 3).screen
    GUARDS.map { |under, clear| [screen.pixel(*under), screen.pixel(*clear)] }
  end

  def test_in_front_of_the_arch_every_guard_shows_whole
    assert_equal [[RED, RED]] * 2, pixels(arch(0))
  end

  def test_behind_the_arch_every_guard_is_covered_where_it_stands_under_it
    assert_equal [[BLUE, RED]] * 2, pixels(arch(1))
  end

  # --- what it refuses ---

  def test_a_layer_the_stack_does_not_have_is_refused_naming_the_pool
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
        layers :ground, :upper
        guards = layer(:upper) { pool :guards, x: 0, y: 0, capacity: 4, image: :guy }
        game_loop { guards.put_in_layer :stairz }
      end
    end

    assert_match(/The pool :guards/, error.message)
    assert_match(/no layer of that name/, error.message)
  end

  def test_a_pool_that_draws_nothing_is_told_it_has_nothing_to_move
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        layers :ground, :upper
        bullets = pool :bullets, x: 0, y: 0, capacity: 4
        game_loop { bullets.put_in_layer :ground }
      end
    end

    assert_match(/draw nothing/, error.message)
  end

  def test_a_pool_in_a_draw_in_order_cannot_change_layer
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
        layers :ground, :upper
        guards = layer(:upper) { pool :guards, x: 0, y: 0, capacity: 4, image: :guy }
        draw_in_order guards
        game_loop { guards.put_in_layer :ground }
      end
    end

    assert_match(/cannot change layer/, error.message)
  end
end
