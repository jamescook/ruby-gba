# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_pool_walk_order"

# A POOL WALKED IN THE ORDER ITS THINGS WERE ADDED, on the Advance's cartridge: the same games
# played in the emulator, their variables read back, and the same orders expected as every run
# reads in test/all/vblank/dsl/test_pool_walk_order.rb.
class TestPoolWalkOrderCartridge < Minitest::Test
  include PoolWalkOrderGames

  # The game's Advance cartridge, played +frames+ frames in the emulator from +save+.
  private def cartridge_of(game, frames:, save: nil)
    rom = game.build_rom(out: nil, err: nil, profile: false)
    assert_emulator_loads_rom(rom, frames: frames, vars: rom.var_addresses, **{ save: save }.compact)
  end

  # The cartridge reads +expected+ as [:first, :order] after enough frames for every event to
  # have happened and the walk to have settled.
  private def assert_orders(expected, game, frames: 8)
    console = cartridge_of(game, frames: frames)
    assert_equal expected, [console.var(:first), console.var(:order)], "on the Advance's cartridge"
  end

  def test_things_are_walked_in_the_order_they_were_spawned
    assert_orders [123, 123], spawn_order_game
  end

  def test_a_thing_spawned_into_a_freed_slot_is_walked_last
    assert_orders [123, 134], freed_slot_game
  end

  def test_a_thing_that_removes_itself_does_not_stop_the_walk
    assert_orders [123, 23], self_removing_game
  end

  def test_a_thing_removed_before_its_turn_is_passed_over
    assert_orders [12, 12], removed_before_turn_game
  end

  def test_a_thing_spawned_during_the_walk_waits_for_the_next_walk
    assert_orders [123, 129], spawned_during_walk_game
  end

  def test_a_full_pool_recycles_its_first_thing_and_walks_the_new_one_last
    assert_orders [123, 234], recycling_game
  end

  def test_a_full_pool_recycling_inside_its_own_walk_drops_the_spawn
    assert_orders [123, 123], recycling_inside_walk_game
  end

  def test_a_newest_first_walk_is_the_reverse_of_spawn_order
    assert_orders [321, 321], newest_first_game
  end

  def test_a_newest_first_walk_starts_at_a_thing_spawned_into_a_freed_slot
    assert_orders [321, 431], newest_first_freed_slot_game
  end

  def test_a_thing_that_removes_itself_does_not_stop_a_newest_first_walk
    assert_orders [321, 21], newest_first_self_removing_game
  end

  def test_a_newest_first_walk_inside_one_keeps_its_place
    assert_orders [32, 32], newest_first_nested_walk_game
  end

  def test_a_thing_spawned_during_a_newest_first_walk_waits_for_the_next_walk
    assert_orders [321, 932], newest_first_spawned_during_walk_game
  end

  def test_a_newest_first_walk_starts_at_the_thing_a_full_pool_recycled_for
    assert_orders [321, 432], newest_first_recycling_game
  end

  def test_a_full_pool_recycling_inside_its_own_newest_first_walk_drops_the_spawn
    assert_orders [321, 321], newest_first_recycling_inside_walk_game
  end

  # The slot C sits in is the interpreter's, and the cartridge hands the routine the same one.
  def test_a_pool_routine_called_from_a_newest_first_walk_gets_each_thing_in_turn
    game = pool_routine_game
    slot_of_c = game_player.run(game.program, frames: 2).pool(:thing, :id).index(3)
    console = cartridge_of(game, frames: 4)

    assert_equal [321, slot_of_c], [console.var(:order), console.var(:first_slot)], "on the Advance's cartridge"
  end

  # The cartridge rolls the numbers the interpreter rolls, whatever slots the things landed in.
  def test_random_numbers_are_rolled_in_the_order_things_were_spawned
    plain = rolls(rolling_game(shuffled: false))

    [false, true].each do |shuffled|
      console = cartridge_of(rolling_game(shuffled: shuffled), frames: 6)
      assert_equal plain, [console.var(:first_roll), console.var(:second_roll)], "on the Advance's cartridge"
    end
  end

  # The save is made on the interpreter, and the cartridge starts from it.
  def test_a_saved_pool_loads_back_in_its_order
    game = saved_pool_game

    assert_equal 234, cartridge_of(game, frames: 6, save: save_made_by(game)).var(:first), "on the Advance's cartridge"
  end

  def test_a_spawn_after_loading_a_save_made_during_a_walk_appears
    game = save_during_walk_game

    assert_equal 234, cartridge_of(game, frames: 6, save: save_made_by(game)).var(:first), "on the Advance's cartridge"
  end

  def test_full_agrees_with_spawn_during_a_walk
    console = cartridge_of(full_during_walk_game, frames: 8)

    assert_equal [1, 0], [console.var(:said_full_during), console.var(:said_full_after)], "on the Advance's cartridge"
  end

  def test_a_large_pool_walks_in_order
    assert_equal 200, cartridge_of(large_pool_game, frames: 4).var(:in_place), "on the Advance's cartridge"
  end
end
