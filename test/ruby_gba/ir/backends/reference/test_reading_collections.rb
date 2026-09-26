# frozen_string_literal: true

require "test_helper"

# READING A GAME'S COLLECTIONS AFTER A RUN. A test reads a variable with `run[:score]`; a
# list, and every field of a pool, is read the same way — by the name the game declared it
# with — rather than by reaching into how the interpreter happens to keep them.
class TestReadingCollections < Minitest::Test
  private def ran(frames: 3, &block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    Reference.new.run(builder.program, frames: frames)
  end

  def test_a_list_reads_back_what_the_game_put_in_it
    run = ran do
      trail = list :trail, capacity: 8
      game_loop { trail.push 7 }
    end

    assert_equal [7, 7, 7], run.list(:trail)
  end

  # A shifted list reads oldest first, which is the order the game reads it in.
  def test_a_list_reads_oldest_first
    run = ran(frames: 4) do
      n = var :n, 0
      queue = list :queue, capacity: 2
      game_loop do
        n.add! 1
        (queue.length == 2).then { queue.shift }
        queue.push n
      end
    end

    assert_equal [3, 4], run.list(:queue)
  end

  # A pool's field reads one entry per slot: the value where an instance is live, and nil
  # where the slot is free. Slots are handed out from the last one down, so the first spawn
  # is in the last slot — the same slot the console gives it.
  def test_a_pool_field_reads_per_slot
    run = ran(frames: 2) do
      guards = pool :guard, x: 0, hp: 3, capacity: 4
      guards.spawn(x: 10)
      guards.spawn(x: 20, hp: 1)
      game_loop { guards.each { |g| g.x.add! 1 } }
    end

    assert_equal [nil, nil, 22, 12], run.pool(:guard, :x)
    assert_equal [nil, nil, 1, 3], run.pool(:guard, :hp)
  end

  # A pool whose name has an underscore in it is found whole, not taken for a shorter pool
  # with a longer field.
  def test_a_pool_name_with_an_underscore_is_found
    run = ran(frames: 1) do
      shots = pool :enemy_shot, x_speed: 0, capacity: 2
      shots.spawn(x_speed: 5)
      game_loop { wait_vblank }
    end

    assert_equal [nil, 5], run.pool(:enemy_shot, :x_speed)
  end

  def test_an_unknown_list_is_a_friendly_error_naming_the_lists
    run = ran { list :trail, capacity: 8; game_loop { wait_vblank } }
    error = assert_raises(ArgumentError) { run.list(:trial) }

    assert_match(/no list :trial/, error.message)
    assert_match(/:trail/, error.message)
  end

  def test_an_unknown_pool_or_field_is_a_friendly_error_naming_what_there_is
    run = ran do
      pool :guard, x: 0, hp: 3, capacity: 4
      game_loop { wait_vblank }
    end

    assert_match(/no pool :gaurd.*:guard/m, assert_raises(ArgumentError) { run.pool(:gaurd, :x) }.message)
    field = assert_raises(ArgumentError) { run.pool(:guard, :y) }.message
    assert_match(/no field :y/, field)
    assert_match(/:hp/, field)
    refute_match(/:active|:free/, field, "the pool's own bookkeeping is not a field")
  end
end
