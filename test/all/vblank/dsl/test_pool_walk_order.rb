# frozen_string_literal: true

require "test_helper"

# The games whose walks are read, shared with the Advance cartridge's own tests of the same
# orders (test/lowering/gba/vblank/dsl/test_pool_walk_order_cartridge.rb). Each gives its things
# an id and writes the order a walk visits them as one number, a digit per thing: 123 is 1,
# then 2, then 3.
module PoolWalkOrderGames
  # A game whose pool of +capacity+ things is walked once a pass, the order written into
  # :order, and the order the first pass's walk wrote kept in :first. +setup+ runs before the
  # loop; +pass+ runs in the loop before the walk, given the pool and the pass number;
  # +visit+ runs on each thing in the walk, given the pool, it and the pass number.
  private def walking_game(capacity: 4, on_full: :drop, setup: nil, pass: nil, visit: nil, newest_first: false)
    VBlank.game("WALKORDER", consoles: %i[gba]) do
      screen :bitmap
      order = var :order, 0
      first = var :first, 0
      passes = var :passes, 0
      things = pool :thing, id: 0, capacity: capacity, on_full: on_full
      instance_exec(things, &setup) if setup
      game_loop do
        instance_exec(things, passes, &pass) if pass
        order.set! 0
        things.each(newest_first: newest_first) do |t|
          order.set! order * 10 + t.id
          instance_exec(things, t, passes, &visit) if visit
        end
        (passes == 0).then { first.set! order }
        passes.add! 1
      end
    end
  end

  # Spawn things with these ids, in this order.
  private def spawning(*ids) = ->(things) { ids.each { |id| things.spawn id: id } }

  private def spawn_order_game = walking_game(setup: spawning(1, 2, 3))

  # B's slot is the one freed last, so D takes it — and is still walked last.
  private def freed_slot_game
    walking_game(setup: spawning(1, 2, 3),
                 visit: ->(_things, t, passes) { ((passes == 0) & (t.id == 2)).then { t.remove } },
                 pass: ->(things, passes) { (passes == 1).then { things.spawn id: 4 } })
  end

  # A removes itself on its turn, and the walk goes on to B and C, each once.
  private def self_removing_game
    walking_game(setup: spawning(1, 2, 3),
                 visit: ->(_things, t, passes) { ((passes == 0) & (t.id == 1)).then { t.remove } })
  end

  # A removes C before C's turn: the walk passes C over. B removes A, which has had its turn.
  private def removed_before_turn_game
    walking_game(setup: spawning(1, 2, 3),
                 visit: lambda { |things, t, passes|
                   ((passes == 0) & (t.id == 1)).then do
                     things.each { |other| (other.id == 3).then { other.remove } }
                   end
                 })
  end

  # The last thing removes itself and a spawn takes its slot at once, inside the walk: the
  # walk still ends there, and the new thing is first walked on the next pass.
  private def spawned_during_walk_game
    walking_game(setup: spawning(1, 2, 3),
                 visit: lambda { |things, t, passes|
                   ((passes == 0) & (t.id == 3)).then do
                     t.remove
                     things.spawn id: 9
                   end
                 })
  end

  # A pool full and recycling its oldest drops A and walks the newcomer last.
  private def recycling_game
    walking_game(capacity: 3, on_full: :recycle_oldest, setup: spawning(1, 2, 3),
                 pass: ->(things, passes) { (passes == 1).then { things.spawn id: 4 } })
  end

  # Inside its own walk a full recycling pool cannot move its first thing, so the spawn is
  # dropped, as a pool that drops always does.
  private def recycling_inside_walk_game
    walking_game(capacity: 3, on_full: :recycle_oldest, setup: spawning(1, 2, 3),
                 visit: ->(things, t, passes) { ((passes == 0) & (t.id == 2)).then { things.spawn id: 4 } })
  end

  # A WALK CAN GO THE OTHER WAY, newest first, where the last thing added has to act first.
  # It is the exact reverse of the walk above, and what each promises during a walk holds
  # the same way round.
  private def newest_first_game = walking_game(setup: spawning(1, 2, 3), newest_first: true)

  # D takes B's freed slot and, as the newest, is walked first.
  private def newest_first_freed_slot_game
    walking_game(setup: spawning(1, 2, 3), newest_first: true,
                 visit: ->(_things, t, passes) { ((passes == 0) & (t.id == 2)).then { t.remove } },
                 pass: ->(things, passes) { (passes == 1).then { things.spawn id: 4 } })
  end

  # C, walked first, removes itself, and the walk goes on to B and A.
  private def newest_first_self_removing_game
    walking_game(setup: spawning(1, 2, 3), newest_first: true,
                 visit: ->(_things, t, passes) { ((passes == 0) & (t.id == 3)).then { t.remove } })
  end

  # C walks the pool again, newest first, and removes A there: the inner walk ends, the outer
  # one carries on from where it was to B, and passes A over.
  private def newest_first_nested_walk_game
    walking_game(setup: spawning(1, 2, 3), newest_first: true,
                 visit: lambda { |things, t, passes|
                   ((passes == 0) & (t.id == 3)).then do
                     things.each(newest_first: true) { |other| (other.id == 1).then { other.remove } }
                   end
                 })
  end

  # A, walked last, removes itself and a spawn arrives in the same walk: the new thing is
  # first walked on the next pass, where it is the newest.
  private def newest_first_spawned_during_walk_game
    walking_game(setup: spawning(1, 2, 3), newest_first: true,
                 visit: lambda { |things, t, passes|
                   ((passes == 0) & (t.id == 1)).then do
                     t.remove
                     things.spawn id: 9
                   end
                 })
  end

  # A full pool recycling its oldest drops A, and the newcomer, as the newest, is walked first.
  private def newest_first_recycling_game
    walking_game(capacity: 3, on_full: :recycle_oldest, setup: spawning(1, 2, 3), newest_first: true,
                 pass: ->(things, passes) { (passes == 1).then { things.spawn id: 4 } })
  end

  # Inside its own walk a full recycling pool cannot move its first thing, which is where a
  # newest-first walk stops, so the spawn is dropped here too.
  private def newest_first_recycling_inside_walk_game
    walking_game(capacity: 3, on_full: :recycle_oldest, setup: spawning(1, 2, 3), newest_first: true,
                 visit: ->(things, t, passes) { ((passes == 0) & (t.id == 2)).then { things.spawn id: 4 } })
  end

  # A routine of the pool's, called from a newest-first walk, is handed each thing in that
  # order, and the slot it is handed is the thing's own: :first_slot is where C sits.
  private def pool_routine_game
    VBlank.game("WALKROUTINE", consoles: %i[gba]) do
      screen :bitmap
      order = var :order, 0
      first_slot = var :first_slot, -1
      things = pool :thing, id: 0, capacity: 4
      [1, 2, 3].each { |id| things.spawn id: id }
      things.func(:visit) do |t|
        (order == 0).then { first_slot.set! t.index }
        order.set! order * 10 + t.id
      end
      game_loop do
        order.set! 0
        things.each(newest_first: true) { call :visit }
      end
    end
  end

  # TWO THINGS ROLL THE SAME NUMBERS WHATEVER SLOTS THEY LANDED IN. Both games spawn 1 then 2
  # on the third pass and walk them on the fourth, each rolling as it is visited. In the plain
  # game 1 takes the highest slot and 2 the one below it. The other first spawns 7, 8 and 9 and
  # removes 7 and then 9 on passes of their own, which hands 1 a lower slot than 2 — so walked
  # by slot, the two games would roll in opposite orders.
  private def rolling_game(shuffled:)
    VBlank.game("WALKROLL", consoles: %i[gba]) do
      screen :bitmap
      seed 42
      first_roll = var :first_roll, 0
      second_roll = var :second_roll, 0
      passes = var :passes, 0
      things = pool :thing, id: 0, capacity: 4
      [7, 8, 9].each { |id| things.spawn id: id } if shuffled
      game_loop do
        (passes == 2).then do
          things.spawn id: 1
          things.spawn id: 2
        end
        things.each do |t|
          ((passes == 0) & (t.id == 7)).then { t.remove }
          ((passes == 1) & (t.id == 9)).then { t.remove }
          ((passes == 3) & (t.id == 1)).then { first_roll.set! rand(0..999) }
          ((passes == 3) & (t.id == 2)).then { second_roll.set! rand(0..999) }
        end
        passes.add! 1
      end
    end
  end

  # The two rolls the game makes, after the walk that rolls.
  private def rolls(game)
    run = game_player.run(game.program, frames: 6)
    [run[:first_roll], run[:second_roll]]
  end

  # A KEPT POOL COMES BACK IN ITS ORDER. The first run removes 1 and spawns 4 into its slot,
  # then saves; the second run loads that save at power-on and its first walk goes 2, 3, 4.
  private def saved_pool_game
    VBlank.game("WALKSAVE", consoles: %i[gba]) do
      screen :bitmap
      order = var :order, 0
      first = var :first, 0
      passes = var :passes, 0
      things = pool :thing, id: 0, capacity: 4
      level = save_data(:level) { keep things }
      level[0].good?.then { level[0].load }.else { [1, 2, 3].each { |id| things.spawn id: id } }
      game_loop do
        (passes == 1).then { things.spawn id: 4 }
        (passes == 2).then { level[0].save }
        order.set! 0
        things.each do |t|
          order.set! order * 10 + t.id
          ((passes == 0) & (t.id == 1)).then { t.remove }
        end
        (passes == 0).then { first.set! order }
        passes.add! 1
      end
    end
  end

  # A SAVE MADE DURING A WALK, AFTER A REMOVAL, holds a thing the walk has not yet let go of.
  # Loaded at power-on, the next spawn into the full pool still appears: 1 was removed, so
  # there is room for 4 without recycling 2.
  private def save_during_walk_game
    VBlank.game("WALKSAVE2", consoles: %i[gba]) do
      screen :bitmap
      first = var :first, 0
      order = var :order, 0
      passes = var :passes, 0
      things = pool :thing, id: 0, capacity: 3, on_full: :recycle_oldest
      level = save_data(:level) { keep things }
      level[0].good?.then do
        level[0].load
        things.spawn id: 4
      end.else { [1, 2, 3].each { |id| things.spawn id: id } }
      game_loop do
        order.set! 0
        things.each do |t|
          order.set! order * 10 + t.id
          ((passes == 0) & (t.id == 1)).then do
            t.remove
            level[0].save
          end
        end
        (passes == 0).then { first.set! order }
        passes.add! 1
      end
    end
  end

  # The save +game+ makes on its first run, made on the interpreter.
  private def save_made_by(game)
    image = VBlank::IR::SaveImage.new
    game_player(save: image).run(game.program, frames: 10)
    image
  end

  # `full?` says what a spawn will find: during a walk a removed thing's slot is not free
  # yet, so a pool that had no room still has none, and after the walk it has one.
  private def full_during_walk_game
    walking_game(capacity: 2, setup: spawning(1, 2),
                 visit: lambda { |things, t, passes|
                   said = var :said_full_during, 0
                   ((passes == 0) & (t.id == 1)).then do
                     t.remove
                     things.full?.then { said.set! 1 }
                   end
                 },
                 pass: lambda { |things, passes|
                   said = var :said_full_after, 0
                   (passes == 1).then { things.full?.then { said.set! 1 } }
                 })
  end

  # A pool bigger than a byte's half holds slot numbers past 127, and still walks in order.
  # Each thing is visited where its id says: :in_place counts the ones that were.
  private def large_pool_game
    VBlank.game("WALKBIG", consoles: %i[gba]) do
      screen :bitmap
      in_place = var :in_place, 0
      expected = var :expected, 0
      things = pool :thing, id: 0, capacity: 200
      200.times { |n| things.spawn id: n }
      game_loop do
        in_place.set! 0
        expected.set! 0
        things.each do |t|
          (t.id == expected).then { in_place.add! 1 }
          expected.add! 1
        end
      end
    end
  end
end

# A POOL IS WALKED IN THE ORDER ITS THINGS WERE ADDED, whatever slot each landed in: a thing
# removed leaves the order, and a new one always goes last. Games depend on it where a player
# can see it — things that roll random numbers one after another, and things that act on
# each other first come, first served.
#
# Each game (in PoolWalkOrderGames, above) writes the order a walk visits its things as one
# number. Every run must read the number written here, and the Advance's cartridge reads the
# same in test/lowering/gba/vblank/dsl/test_pool_walk_order_cartridge.rb.
class TestPoolWalkOrder < Minitest::Test
  include PoolWalkOrderGames

  # The game's run reads +expected+ as [:first, :order] after enough frames for every event to
  # have happened and the walk to have settled.
  private def assert_orders(expected, game, frames: 8)
    run = game_player.run(game.program, frames: frames)
    assert_equal expected, [run[:first], run[:order]]
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

  def test_a_pool_routine_called_from_a_newest_first_walk_gets_each_thing_in_turn
    run = game_player.run(pool_routine_game.program, frames: 2)
    slot_of_c = run.pool(:thing, :id).index(3)

    assert_equal [321, slot_of_c], [run[:order], run[:first_slot]]
  end

  def test_a_walk_order_that_is_not_true_or_false_is_a_friendly_error
    err = assert_raises(ArgumentError) { walking_game(newest_first: :yes).program }
    assert_match(/needs true or false/, err.message)
  end

  # The slots 1 and 2 landed in, after the walk that rolls.
  private def slots_of_one_and_two(game)
    run = game_player.run(game.program, frames: 6)
    ids = run.pool(:thing, :id) # an entry a slot, nil where the slot is free
    [1, 2].map { |id| ids.index(id) }
  end

  def test_random_numbers_are_rolled_in_the_order_things_were_spawned
    plain = rolls(rolling_game(shuffled: false))
    plain_slots = slots_of_one_and_two(rolling_game(shuffled: false))
    shuffled_slots = slots_of_one_and_two(rolling_game(shuffled: true))

    assert_operator plain_slots.first, :>, plain_slots.last, "plain: 1 sits above 2"
    assert_operator shuffled_slots.first, :<, shuffled_slots.last, "shuffled: 1 sits below 2"
    refute_equal plain.first, plain.last, "the two rolls differ, so an order shows"
    assert_equal plain, rolls(rolling_game(shuffled: true))
  end

  # The save is made on the interpreter, and the game starts from it.
  def test_a_saved_pool_loads_back_in_its_order
    game = saved_pool_game
    loaded = game_player(save: save_made_by(game)).run(game.program, frames: 1)

    assert_equal 234, loaded[:first]
  end

  def test_a_spawn_after_loading_a_save_made_during_a_walk_appears
    game = save_during_walk_game
    loaded = game_player(save: save_made_by(game)).run(game.program, frames: 1)

    assert_equal 234, loaded[:first]
  end

  def test_full_agrees_with_spawn_during_a_walk
    run = game_player.run(full_during_walk_game.program, frames: 4)

    assert_equal [1, 0], [run[:said_full_during], run[:said_full_after]]
  end

  def test_a_large_pool_walks_in_order
    run = game_player.run(large_pool_game.program, frames: 2)

    assert_equal 200, run[:in_place]
  end
end
