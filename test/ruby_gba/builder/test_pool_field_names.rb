# frozen_string_literal: true

require "test_helper"

# WHAT A POOL'S FIELDS CAN BE CALLED. A pool keeps lists and variables of its own beside the
# fields — which slots are live, where each instance is in its animation, the order they came
# in — and a field is a list too. A guard with a field called `frame`, `active` or `count` is
# an ordinary thing to write, so none of the pool's own names can be a name a field has, and
# two pools cannot meet each other's whatever they and their fields are called.
class TestPoolFieldNames < Minitest::Test
  runs_on :reference, :native

  RED = Color.resolve(:red)
  GREEN = Color.resolve(:green)
  YELLOW = Color.resolve(:yellow)

  OWN = %i[transparent red green].freeze
  HURT = %i[transparent yellow white].freeze

  private def tiled_program(&game)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :one, width: 8, height: 8, data: Array.new(64, :red), colors: OWN
      image :two, width: 8, height: 8, data: Array.new(64, :green), colors: OWN
      colors :hurt, HURT
      instance_eval(&game)
    end
    builder.finalize_program
    builder.program
  end

  # The variable +name+ after +frames+ frames, on the interpreter and on the console.
  private def var_on_both_backends(prog, name, frames: 4)
    rom = assemble_rom(prog)
    console = assert_emulator_loads_rom(rom, frames: frames + 2, vars: rom.var_addresses)
    [game_player.run(prog, frames: frames)[name], console.var(name)]
  end

  private def refused(&game)
    assert_raises(ArgumentError) { Builder.new.instance_eval(&game) }.message
  end

  # --- a field called what the pool calls one of its own lists ---

  def test_a_field_called_frame_keeps_its_number_on_a_pool_that_animates
    prog = tiled_program do
      things = pool :thing, x: 0, y: 0, frame: 7, capacity: 2, frames: %i[one two], rate: 2
      seen = var :seen, 0
      things.spawn x: 20, y: 20
      game_loop { things.each { |t| seen.set! t.frame } }
    end

    assert_equal [7, 7], var_on_both_backends(prog, :seen), "the field is the number it was given"
    shown = (3..8).map { |frames| game_player.run(prog, frames: frames).screen.pixel(22, 22) }
    assert_equal [RED, GREEN].sort, shown.uniq.sort, "and the pool still steps through its pictures"
  end

  def test_a_field_called_colors_keeps_its_number_on_a_pool_told_to_draw_with_others
    prog = tiled_program do
      things = pool :thing, x: 0, y: 0, colors: 5, capacity: 2, image: :one
      seen = var :seen, 0
      things.spawn x: 20, y: 20
      game_loop do
        things.each do |t|
          t.draw_with :hurt
          seen.set! t.colors
        end
      end
    end

    assert_equal [5, 5], var_on_both_backends(prog, :seen)
    assert_equal YELLOW, game_player.run(prog, frames: 4).screen.pixel(22, 22), "and it is recoloured"
  end

  # Every word the pool spells one of its own lists, variables or routines with, as a field,
  # and the words a pool answers to itself. Each instance writes its own number into each and
  # reads it back after a spawn, a removal and a walk have used the pool's own.
  OWN_WORDS = %i[active free count slot current next prev retired head tail walking tick
                 unlink before after release fill refill anim stacked stackedx append
                 spawn each full func name field step].freeze

  def test_a_field_can_be_called_anything_the_pool_calls_its_own
    words = OWN_WORDS
    prog = tiled_program do
      things = pool :thing, x: 0, y: 0, capacity: 4, frames: %i[one two], rate: 2, **words.to_h { |word| [word, 0] }
      sum = var :sum, 0
      live = var :live, 0
      3.times { |n| things.spawn x: 20 * n, y: 20, **words.each_with_index.to_h { |word, at| [word, at + n] } }
      game_loop do
        things.each { |t| (t.x == 20).then { t.remove } }
        sum.set! 0
        things.each { |t| words.each { |word| sum.add! t.public_send(word) } }
        live.set! things.count
      end
    end

    each = words.size * (words.size - 1) / 2
    assert_equal [(2 * each) + (2 * words.size)] * 2, var_on_both_backends(prog, :sum),
                 "the first and third instance's numbers, as they were written"
    assert_equal [2, 2], var_on_both_backends(prog, :live)
  end

  # --- two pools ---

  def test_two_pools_whose_names_and_fields_spell_the_same_words_are_kept_apart
    prog = tiled_program do
      short = pool :guard, walk_x: 0, walk_active: 0, capacity: 2
      long = pool :guard_walk, x: 0, capacity: 2
      seen = var :seen, 0
      long_seen = var :long_seen, 0
      short.spawn walk_x: 3, walk_active: 9
      long.spawn x: 40
      game_loop do
        short.each { |g| seen.set! (g.walk_x * 10) + g.walk_active }
        long.each { |g| long_seen.set! g.x }
      end
    end

    assert_equal [39, 39], var_on_both_backends(prog, :seen)
    assert_equal [40, 40], var_on_both_backends(prog, :long_seen)
  end

  def test_the_interpreter_offers_each_pools_own_fields
    prog = tiled_program do
      short = pool :guard, walk_x: 0, active: 0, capacity: 2
      long = pool :guard_walk, x: 0, capacity: 2
      short.spawn walk_x: 3, active: 9
      long.spawn x: 40
      game_loop {}
    end
    run = game_player.run(prog)

    assert_equal({ guard: { walk_x: [3], active: [9] }, guard_walk: { x: [40] } },
                 run.game_state[:pools].transform_values { |fields| fields.transform_values(&:compact) })
    assert_equal [9], run.pool(:guard, :active).compact
  end

  # --- what a name cannot be ---

  def test_a_field_called_what_an_instance_already_answers_to_is_a_friendly_error
    %i[remove index move left draw_with].each do |word|
      message = refused { pool :p, capacity: 8, word => 0 }
      assert_match(/:#{word}\b/, message)
      assert_match(/already/, message, "it says why")
    end
  end

  # A field is written the way the pool's own words are, so one spelled like a word of the
  # pool's is taken for it. Each says so, and none is quietly left out of the pool.
  def test_a_field_spelled_like_a_word_of_the_pool_is_a_friendly_error
    { facing: 0, rate: 5, fast: 1 }.each do |word, value|
      message = refused { pool :p, x: 0, y: 0, capacity: 8, word => value }
      assert_match(/#{word}: #{value}/, message)
      assert_match(/word of the pool/, message)
      assert_match(/different name/, message)
    end
  end

  def test_a_pool_name_that_would_run_into_its_own_parts_is_a_friendly_error
    assert_match(/underscore/, refused { pool :guard_, x: 0, capacity: 2 })
    assert_match(/underscore/, refused { pool :guard__walk, x: 0, capacity: 2 })
  end
end
