# frozen_string_literal: true

require "test_helper"

# A LIST SET TO ONE VALUE IN ONE STEP: `list.fill value`, or a run of it, `list.fill value,
# from: f, count: n`. Clearing a box a game letters text into is the case: thousands of bytes
# set to one value when the box opens, which a loop setting them one at a time spends most of
# a frame on.
class TestListFillWord < Minitest::Test
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

  private def interpreted(game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    run = Reference.new.run(builder.program, frames: 3)
    READINGS.map { |name| run[name] }
  end

  private def on_console(game)
    rom = RubyGBA.build("LISTFILL", out: StringIO.new, err: StringIO.new, profile: false, &game)
    v = assert_emulator_loads_rom(rom, frames: 4, vars: rom.var_addresses)
    READINGS.map { |name| v.var(name) }
  end

  def test_the_whole_list_takes_a_value_worked_out_as_the_game_runs
    game = filling { |canvas, shade| canvas.fill shade }

    assert_equal [0x77, 0x77, 0x77, 0x77, 0x77, SIZE], interpreted(game)
    assert_equal interpreted(game), on_console(game)
  end

  # A byte that reads below nothing goes in as the console's byte does: 0xFF is -1.
  def test_a_run_from_a_worked_out_start_sets_only_those_items
    game = filling { |canvas, _shade, start| canvas.fill 0xFF, from: start, count: start - 2 }

    assert_equal [0, 0, -1, 0, 0, SIZE], interpreted(game)
    assert_equal interpreted(game), on_console(game)
  end

  # WHAT IT IS FOR: a dialogue box's 3,328 bytes cleared on the frame it opens. One at a time
  # from the cartridge, that is most of a frame; filled, a small part of one.
  def test_clearing_a_box_every_frame_takes_a_small_part_of_it
    rom = RubyGBA.build("CLEARBOX", out: StringIO.new, err: StringIO.new, profile: false, fast_code: false,
                                    &filling { |canvas, shade| canvas.fill shade })
    result = RubyGBA::Diagnostics::Profiler.run(rom, frames: 30, picture: false)

    assert_operator result.idle_share, :>, 0.95, "the clear left #{result.idle_share} of the frame"
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
end
