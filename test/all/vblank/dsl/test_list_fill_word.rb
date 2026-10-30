# frozen_string_literal: true

require "test_helper"

# The games these tests play, shared with the Advance cartridge's own tests of the same fills
# (test/lowering/gba/vblank/dsl/test_list_fill_word_cartridge.rb).
module ListFillWordGames
  SIZE = 3328

  # A byte list of SIZE items, all 0, filled each pass as +fill+ says, with a few items read
  # into variables so both backends can be read the same way.
  private def filling(&fill)
    proc do
      screen :tiled
      # A full build refuses a tiled screen with nothing on it.
      image(:dot, "#" => :white) { "########\n" * 8 }
      sprite :dot, at: [0, 0]
      canvas = list :canvas, capacity: SIZE, width: :byte, fast: false
      repeat(SIZE) { canvas.push 0 }
      shade = var :shade, 0x77
      start = var :start, 5
      readings = %i[first before inside after last held].to_h { |name| [name, var(name, 0)] }
      game_loop do
        instance_exec(canvas, shade, start, &fill)
        { first: 0, before: 4, inside: 6, after: 8, last: SIZE - 1 }.each { |name, at| readings[name].set! canvas[at] }
        readings[:held].set! canvas.length
      end
    end
  end

  READINGS = %i[first before inside after last held].freeze
end

# A LIST SET TO ONE VALUE IN ONE STEP: `list.fill value`, or a run of it, `list.fill value,
# from: f, count: n`. Clearing a box a game letters text into is the case: thousands of bytes
# set to one value when the box opens, which a loop setting them one at a time spends most of
# a frame on. The same fills on the Advance's cartridge, and what one costs there, are in
# test/lowering/gba/vblank/dsl/test_list_fill_word_cartridge.rb.
class TestListFillWord < Minitest::Test
  include ListFillWordGames

  private def interpreted(game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    run = game_player.run(builder.program, frames: 3)
    READINGS.map { |name| run[name] }
  end

  def test_the_whole_list_takes_a_value_worked_out_as_the_game_runs
    game = filling { |canvas, shade| canvas.fill shade }

    assert_equal [0x77, 0x77, 0x77, 0x77, 0x77, SIZE], interpreted(game)
  end

  # A byte that reads below nothing goes in as the console's byte does: 0xFF is -1.
  def test_a_run_from_a_worked_out_start_sets_only_those_items
    game = filling { |canvas, _shade, start| canvas.fill 0xFF, from: start, count: start - 2 }

    assert_equal [0, 0, -1, 0, 0, SIZE], interpreted(game)
  end

  private def refused(&game)
    builder = Builder.new
    assert_raises(ArgumentError) { builder.instance_eval(&game) }.message
  end

  def test_a_fill_that_cannot_be_made_is_a_friendly_error
    assert_match(/holds 4/, refused { list(:l, capacity: 4, width: :byte).fill 1, from: 2, count: 3 })
    assert_match(/from: -1/, refused { list(:l, capacity: 4, width: :byte).fill 1, from: -1, count: 2 })
    assert_match(/read-only/, refused { table(:t, [1, 2], width: :byte).fill 0 })
    assert_match(/fraction/, refused { list(:l, capacity: 4).fill var(:f, 1.5) })
  end

  # A list the game shifts wraps round its own memory, so a run of its items is not a run of
  # memory to fill — refused once the whole program is known, wherever the shift is written.
  def test_filling_a_list_the_game_shifts_is_a_friendly_error
    builder = Builder.new
    error = assert_raises(ArgumentError) do
      builder.instance_eval do
        queue = list :queue, capacity: 8, width: :byte
        game_loop do
          queue.fill 0
          queue.shift
        end
      end
      builder.finalize_program
    end

    assert_match(/queue/, error.message)
    assert_match(/shift/, error.message)
  end
end
