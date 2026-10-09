# frozen_string_literal: true

require "test_helper"

# A POOL IS WALKED IN THE ORDER ITS THINGS WERE ADDED, whatever slot each landed in: a thing
# removed leaves the order, and a new one always goes last. Games depend on it where a player
# can see it — things that roll random numbers one after another, and things that act on
# each other first come, first served.
#
# Each game below gives its things an id and writes the order a walk visits them as one
# number, a digit per thing: 123 is 1, then 2, then 3. The interpreter and the console must
# read the same number.
class TestPoolWalkOrder < Minitest::Test
  # A game whose pool of +capacity+ things is walked once a pass, the order written into
  # :order, and the order the first pass's walk wrote kept in :first. +setup+ runs before the
  # loop; +pass+ runs in the loop before the walk, given the pool and the pass number;
  # +visit+ runs on each thing in the walk, given the pool, it and the pass number.
  private def walking_game(capacity: 4, on_full: :drop, setup: nil, pass: nil, visit: nil)
    RubyGBA.game("WALKORDER") do
      screen :bitmap
      order = var :order, 0
      first = var :first, 0
      passes = var :passes, 0
      things = pool :thing, id: 0, capacity: capacity, on_full: on_full
      instance_exec(things, &setup) if setup
      game_loop do
        instance_exec(things, passes, &pass) if pass
        order.set! 0
        things.each do |t|
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

  # [:first, :order] after enough frames for every event to have happened and the walk to
  # have settled — on the interpreter, then on the console.
  private def orders(game, frames: 8)
    run = Reference.new.run(game.program, frames: frames)
    rom = game.build_rom(out: nil, err: nil, profile: false)
    console = assert_emulator_loads_rom(rom, frames: frames, vars: rom.var_addresses)
    [[run[:first], run[:order]], [console.var(:first), console.var(:order)]]
  end

  # Both backends read +expected+.
  private def assert_orders(expected, game, frames: 8)
    assert_equal [expected, expected], orders(game, frames: frames)
  end

  def test_things_are_walked_in_the_order_they_were_spawned
    assert_orders [123, 123], walking_game(setup: spawning(1, 2, 3))
  end

  # B's slot is the one freed last, so D takes it — and is still walked last.
  def test_a_thing_spawned_into_a_freed_slot_is_walked_last
    game = walking_game(setup: spawning(1, 2, 3),
                        visit: ->(_things, t, passes) { ((passes == 0) & (t.id == 2)).then { t.remove } },
                        pass: ->(things, passes) { (passes == 1).then { things.spawn id: 4 } })

    assert_orders [123, 134], game
  end

  # A removes itself on its turn, and the walk goes on to B and C, each once.
  def test_a_thing_that_removes_itself_does_not_stop_the_walk
    game = walking_game(setup: spawning(1, 2, 3),
                        visit: ->(_things, t, passes) { ((passes == 0) & (t.id == 1)).then { t.remove } })

    assert_orders [123, 23], game
  end

  # A removes C before C's turn: the walk passes C over. B removes A, which has had its turn.
  def test_a_thing_removed_before_its_turn_is_passed_over
    game = walking_game(setup: spawning(1, 2, 3),
                        visit: lambda { |things, t, passes|
                          ((passes == 0) & (t.id == 1)).then do
                            things.each { |other| (other.id == 3).then { other.remove } }
                          end
                        })

    assert_orders [12, 12], game
  end

  # The last thing removes itself and a spawn takes its slot at once, inside the walk: the
  # walk still ends there, and the new thing is first walked on the next pass.
  def test_a_thing_spawned_during_the_walk_waits_for_the_next_walk
    game = walking_game(setup: spawning(1, 2, 3),
                        visit: lambda { |things, t, passes|
                          ((passes == 0) & (t.id == 3)).then do
                            t.remove
                            things.spawn id: 9
                          end
                        })

    assert_orders [123, 129], game
  end

  # A pool full and recycling its oldest drops A and walks the newcomer last.
  def test_a_full_pool_recycles_its_first_thing_and_walks_the_new_one_last
    game = walking_game(capacity: 3, on_full: :recycle_oldest, setup: spawning(1, 2, 3),
                        pass: ->(things, passes) { (passes == 1).then { things.spawn id: 4 } })

    assert_orders [123, 234], game
  end

  # Inside its own walk a full recycling pool cannot move its first thing, so the spawn is
  # dropped, as a pool that drops always does.
  def test_a_full_pool_recycling_inside_its_own_walk_drops_the_spawn
    game = walking_game(capacity: 3, on_full: :recycle_oldest, setup: spawning(1, 2, 3),
                        visit: ->(things, t, passes) { ((passes == 0) & (t.id == 2)).then { things.spawn id: 4 } })

    assert_orders [123, 123], game
  end

  # TWO THINGS ROLL THE SAME NUMBERS WHATEVER SLOTS THEY LANDED IN. Both games spawn 1 then 2
  # on the third pass and walk them on the fourth, each rolling as it is visited. In the plain
  # game 1 takes the highest slot and 2 the one below it. The other first spawns 7, 8 and 9 and
  # removes 7 and then 9 on passes of their own, which hands 1 a lower slot than 2 — so walked
  # by slot, the two games would roll in opposite orders.
  private def rolling_game(shuffled:)
    RubyGBA.game("WALKROLL") do
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

  # The slots 1 and 2 landed in, after the walk that rolls.
  private def slots_of_one_and_two(game)
    run = Reference.new.run(game.program, frames: 6)
    ids = run.list(:__pool_thing_id)
    live = run.list(:__pool_thing_active)
    [1, 2].map { |id| (0...ids.length).find { |slot| ids[slot] == id && live[slot] == 1 } }
  end

  private def rolls(game)
    run = Reference.new.run(game.program, frames: 6)
    rom = game.build_rom(out: nil, err: nil, profile: false)
    console = assert_emulator_loads_rom(rom, frames: 6, vars: rom.var_addresses)
    [[run[:first_roll], run[:second_roll]], [console.var(:first_roll), console.var(:second_roll)]]
  end

  def test_random_numbers_are_rolled_in_the_order_things_were_spawned
    plain = rolls(rolling_game(shuffled: false))
    plain_slots = slots_of_one_and_two(rolling_game(shuffled: false))
    shuffled_slots = slots_of_one_and_two(rolling_game(shuffled: true))

    assert_operator plain_slots.first, :>, plain_slots.last, "plain: 1 sits above 2"
    assert_operator shuffled_slots.first, :<, shuffled_slots.last, "shuffled: 1 sits below 2"
    assert_equal plain.first, plain.last, "the two backends roll alike"
    refute_equal plain.first.first, plain.first.last, "the two rolls differ, so an order shows"
    assert_equal plain, rolls(rolling_game(shuffled: true))
  end

  # A KEPT POOL COMES BACK IN ITS ORDER. The first run removes 1 and spawns 4 into its slot,
  # then saves; the second run loads that save at power-on and its first walk goes 2, 3, 4.
  # The save is made on the interpreter, and both backends start from it.
  def test_a_saved_pool_loads_back_in_its_order
    game = RubyGBA.game("WALKSAVE") do
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
    image = RubyGBA::IR::SaveImage.new
    Reference.new(save: image).run(game.program, frames: 10)
    loaded = Reference.new(save: image).run(game.program, frames: 1)
    rom = game.build_rom(out: nil, err: nil, profile: false)
    console = assert_emulator_loads_rom(rom, frames: 6, save: image, vars: rom.var_addresses)

    assert_equal [234, 234], [loaded[:first], console.var(:first)]
  end

  # A SAVE MADE DURING A WALK, AFTER A REMOVAL, holds a thing the walk has not yet let go of.
  # Loaded at power-on, the next spawn into the full pool still appears: 1 was removed, so
  # there is room for 4 without recycling 2.
  def test_a_spawn_after_loading_a_save_made_during_a_walk_appears
    game = RubyGBA.game("WALKSAVE2") do
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
    image = RubyGBA::IR::SaveImage.new
    Reference.new(save: image).run(game.program, frames: 10)
    loaded = Reference.new(save: image).run(game.program, frames: 1)
    rom = game.build_rom(out: nil, err: nil, profile: false)
    console = assert_emulator_loads_rom(rom, frames: 6, save: image, vars: rom.var_addresses)

    assert_equal [234, 234], [loaded[:first], console.var(:first)]
  end

  # `full?` says what a spawn will find: during a walk a removed thing's slot is not free
  # yet, so a pool that had no room still has none, and after the walk it has one.
  def test_full_agrees_with_spawn_during_a_walk
    game = walking_game(capacity: 2, setup: spawning(1, 2),
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
    run = Reference.new.run(game.program, frames: 4)
    rom = game.build_rom(out: nil, err: nil, profile: false)
    console = assert_emulator_loads_rom(rom, frames: 8, vars: rom.var_addresses)

    assert_equal [[1, 0], [1, 0]], [[run[:said_full_during], run[:said_full_after]],
                                    [console.var(:said_full_during), console.var(:said_full_after)]]
  end

  # A pool bigger than a byte's half holds slot numbers past 127, and still walks in order.
  # Each thing is visited where its id says: :in_place counts the ones that were.
  def test_a_large_pool_walks_in_order
    game = RubyGBA.game("WALKBIG") do
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
    run = Reference.new.run(game.program, frames: 2)
    rom = game.build_rom(out: nil, err: nil, profile: false)
    console = assert_emulator_loads_rom(rom, frames: 4, vars: rom.var_addresses)

    assert_equal [200, 200], [run[:in_place], console.var(:in_place)]
  end
end
