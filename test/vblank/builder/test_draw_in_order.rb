# frozen_string_literal: true

require "test_helper"
require "differential"

# SPRITES DRAWN IN AN ORDER THE GAME WORKS OUT. A top-down game draws whichever character
# stands lower on the screen in front: walk round below something and you are drawn over it,
# walk round above it and it is drawn over you. The order changes every time two things pass
# each other, so no order fixed when the cartridge is built is right.
#
# Two blocks overlap at OVERLAP. The enemy is declared first, so without an order the hero
# (declared after it) is always in front. Which colour shows there is the whole answer.
class TestDrawInOrder < Minitest::Test
  include Differential

  RED = VBlank::Graphics::Color.resolve(:red)
  GREEN = VBlank::Graphics::Color.resolve(:green)
  BLUE = VBlank::Graphics::Color.resolve(:blue)

  BLOCK = Array.new(16) { "#" * 16 }.join("\n")
  ENEMY_AT = [60, 60].freeze
  OVERLAP = [70, 66].freeze

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # The enemy stands at ENEMY_AT; the hero is eight pixels right of it and +hero_y+ down.
  private def two_program(hero_y, ordered: true, step: 0, hero_named_first: false)
    block = BLOCK
    enemy_at = ENEMY_AT
    program do
      screen :tiled
      image(:enemy, "#" => :red) { block }
      image(:hero, "#" => :green) { block }
      enemy = sprite :enemy, at: enemy_at
      hero = sprite :hero, at: [enemy_at[0] + 8, hero_y]
      draw_in_order(*(hero_named_first ? [hero, enemy] : [enemy, hero])) if ordered
      game_loop { hero.y.add! step unless step.zero? }
    end
  end

  private def shown(prog, frames: 2) = game_player.run(prog, frames: frames).screen.pixel(*OVERLAP)

  def test_without_an_order_the_later_sprite_is_always_in_front
    assert_equal GREEN, shown(two_program(54, ordered: false))
    assert_equal GREEN, shown(two_program(66, ordered: false))
  end

  def test_whoever_stands_lower_is_in_front
    assert_equal RED, shown(two_program(54)), "the hero stands higher, so the enemy covers him"
    assert_equal GREEN, shown(two_program(66)), "the hero stands lower, so he covers the enemy"
  end

  # The things can be named in any order; which is in front follows the numbers, not the list.
  def test_the_things_can_be_named_in_any_order
    assert_equal RED, shown(two_program(54, hero_named_first: true))
    assert_equal GREEN, shown(two_program(66, hero_named_first: true))
    assert_backends_agree(two_program(66, hero_named_first: true), frames: 2)
  end

  def test_the_console_draws_the_same_order
    assert_backends_agree(two_program(54), frames: 2)
    assert_backends_agree(two_program(66), frames: 2)
  end

  # The rows of an ordered run move about the console's table, so asking the console for a
  # sprite by name has to follow them.
  def test_the_console_still_knows_which_sprite_is_which
    v = assert_emulator_loads_rom(assemble_rom(two_program(66), name: "ORDER"), frames: 4)

    assert_equal [[68, 66]], v.sprites(:hero).map { |row| [row.x, row.y] }
    assert_equal [ENEMY_AT], v.sprites(:enemy).map { |row| [row.x, row.y] }
    assert_operator v.sprites(:hero).first.slot, :<, v.sprites(:enemy).first.slot, "the hero is in front"
  end

  # The hero walks down a pixel a frame from above the enemy to below it, and the two swap
  # which is in front on the frame his feet pass the enemy's.
  def test_two_sprites_swap_as_one_walks_past_the_other
    walking = two_program(50, step: 1)
    seen = [4, 14].map { |frames| shown(walking, frames: frames) }

    assert_equal [RED, GREEN], seen
    [4, 14].each { |frames| assert_backends_agree(walking, frames: frames) }
  end

  # THE NUMBER IS THE GAME'S TO WORK OUT. A puff of smoke starts a step nearer the front and
  # drops back; here a variable the game owns decides, and `front: :lowest` reverses it.
  private def keyed_program(boost, front:)
    block = BLOCK
    enemy_at = ENEMY_AT
    program do
      screen :tiled
      image(:enemy, "#" => :red) { block }
      image(:hero, "#" => :green) { block }
      lift = var :lift, boost
      enemy = sprite :enemy, at: enemy_at
      hero = sprite :hero, at: [enemy_at[0] + 8, enemy_at[1] + 4]
      draw_in_order(enemy, hero, front: front) { |thing| thing == hero ? thing.y + lift : thing.y }
      game_loop {}
    end
  end

  def test_the_order_can_be_a_number_the_game_works_out
    assert_equal GREEN, shown(keyed_program(0, front: :highest))
    assert_equal RED, shown(keyed_program(-10, front: :highest))
    assert_equal GREEN, shown(keyed_program(-10, front: :lowest))
    assert_backends_agree(keyed_program(-10, front: :highest), frames: 2)
  end

  # A POOL'S THINGS TAKE PART ONE BY ONE. Two of them are spawned so that the older — which
  # a pool draws in front — stands higher; in order, the lower one covers it instead.
  private def pool_program(ordered: true)
    block = BLOCK
    program do
      screen :tiled
      image(:walker, "#" => :red) { block }
      image(:hero, "#" => :blue) { block }
      walkers = pool :walker, x: 0, y: 0, capacity: 4, image: :walker
      hero = sprite :hero, at: [62, 58]
      draw_in_order walkers, hero if ordered
      walkers.spawn(x: 60, y: 54)
      walkers.spawn(x: 64, y: 62)
      game_loop {}
    end
  end

  def test_a_pools_things_are_ordered_one_by_one
    assert_equal BLUE, shown(pool_program(ordered: false)), "a sprite declared after the pool is in front"
    assert_equal RED, shown(pool_program), "the lower of the pool's things covers the hero"
    assert_backends_agree(pool_program, frames: 2)
  end

  # --- what the build refuses ---

  private def refusal(&block)
    assert_raises(ArgumentError) { program(&block) }.message
  end

  def test_a_bitmap_screen_is_refused
    block = BLOCK
    message = refusal do
      screen :bitmap
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      two = sprite :b, at: [4, 4], facing: { down: :a }
      draw_in_order one, two
    end

    assert_match(/screen :tiled/, message)
  end

  def test_one_sprite_alone_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      draw_in_order one
    end

    assert_match(/two/, message)
  end

  def test_something_that_is_not_a_sprite_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      draw_in_order one, :b
    end

    assert_match(/sprite or a pool/, message)
  end

  def test_a_sprite_in_two_orders_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      two = sprite :b, at: [4, 4], facing: { down: :a }
      three = sprite :c, at: [8, 8], facing: { down: :a }
      draw_in_order one, two
      draw_in_order two, three
    end

    assert_match(/:b/, message)
    assert_match(/one order/, message)
  end

  def test_sprites_in_different_layers_are_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      layers :ground, :sky
      one = layer(:ground) { sprite :a, at: [0, 0] }
      two = layer(:sky) { sprite :b, at: [4, 4], facing: { down: :a } }
      draw_in_order one, two
    end

    assert_match(/layer/, message)
  end

  def test_sprites_in_different_scenes_are_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      scene(:playing) do
        two = sprite :b, at: [4, 4], facing: { down: :a }
        draw_in_order one, two
      end
      var :state, 0
      game_loop { case_var(:state) { when_val 0, :playing } }
    end

    assert_match(/scene/, message)
  end

  def test_a_pool_that_draws_nothing_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      dust = pool :dust, x: 0, y: 0, capacity: 4
      draw_in_order one, dust
    end

    assert_match(/pool :dust draws nothing/, message)
  end

  def test_a_sprite_told_to_change_layer_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      layers :ground, :upper
      one = layer(:ground) { sprite :a, at: [0, 0] }
      two = layer(:ground) { sprite :b, at: [4, 4], facing: { down: :a } }
      draw_in_order one, two
      game_loop { two.put_in_layer :upper }
    end

    assert_match(/put_in_layer/, message)
  end

  def test_an_unknown_front_is_refused
    block = BLOCK
    message = refusal do
      screen :tiled
      image(:a, "#" => :red) { block }
      one = sprite :a, at: [0, 0]
      two = sprite :b, at: [4, 4], facing: { down: :a }
      draw_in_order one, two, front: :top
    end

    assert_match(/:highest/, message)
  end
end
