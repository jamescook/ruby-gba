# frozen_string_literal: true

require "test_helper"

# One column of a picture, stretched to a height the game works out — what a first-person view
# is made of, and what a scaled sprite is.
#
# The stepping rule is the thing worth pinning: walk DOWN THE SCREEN and ask which picture row
# belongs at each screen row. Walking the picture instead and working out where each of its rows
# lands leaves gaps when stretching and writes some rows twice when squashing. Every test here
# is about pixels, on both backends, because the two agreeing is what makes the interpreter
# usable for debugging the renderer.
class TestDrawColumnAt < Minitest::Test
  include GembaSupport

  # Four rows, each its own color, so a stretch is readable row by row.
  BARS = %i[red red green green blue blue white white].freeze
  NAMES = { RubyGBA::Color.resolve(:red) => :red, RubyGBA::Color.resolve(:green) => :green,
            RubyGBA::Color.resolve(:blue) => :blue, RubyGBA::Color.resolve(:white) => :white,
            0 => nil }.freeze

  def program(&block)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image :bars, width: 2, height: 4, data: BARS
    end
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  def column_on_screen(run, x, from, to)
    (from...to).map { |y| NAMES.fetch(run.screen.pixel(x, y), :other) }
  end

  def test_a_column_stretched_to_twice_its_height_shows_each_row_twice
    run = Reference.new.run(program do
      game_loop { draw_column_at :bars, slice: 0, x: 10, top: 0, height: 8 }
    end, frames: 2)

    assert_equal %i[red red green green blue blue white white], column_on_screen(run, 10, 0, 8)
  end

  def test_a_column_squashed_to_half_its_height_drops_the_rows_between
    run = Reference.new.run(program do
      game_loop { draw_column_at :bars, slice: 0, x: 10, top: 0, height: 2 }
    end, frames: 2)

    assert_equal %i[red blue], column_on_screen(run, 10, 0, 2)
  end

  # A height the game works out is the whole point — a wall's height is never known while
  # building.
  def test_a_height_the_game_works_out_stretches_the_same_way
    run = Reference.new.run(program do
      tall = var :tall, 0
      game_loop do
        tall.set 8
        draw_column_at :bars, slice: 0, x: 10, top: 0, height: tall
      end
    end, frames: 2)

    assert_equal %i[red red green green blue blue white white], column_on_screen(run, 10, 0, 8)
  end

  # A wall you are nose-to-nose with is taller than the screen, and one at the far end of a
  # corridor has no height at all. Neither needs a test around it.
  def test_no_height_draws_nothing_and_a_column_past_the_screen_is_clipped
    run = Reference.new.run(program do
      game_loop do
        draw_column_at :bars, slice: 0, x: 10, top: 0, height: 0
        draw_column_at :bars, slice: 0, x: 12, top: -8, height: 24
        draw_column_at :bars, slice: 0, x: 14, top: 155, height: 40
      end
    end, frames: 2)

    assert_equal [nil, nil], column_on_screen(run, 10, 0, 2)
    # top: -8 of 24 means the first third is above the screen, so row 0 shows the picture's
    # middle rather than its first row.
    assert_equal :green, column_on_screen(run, 12, 0, 1).first
    refute_nil column_on_screen(run, 14, 158, 159).first, "the part still on screen is drawn"
  end

  # Many pictures live side by side in one, so a game with a hundred wall pictures needs no
  # runtime choosing — a slice past the end reads the last column rather than whatever is next
  # in memory.
  def test_a_slice_past_the_picture_is_held_to_its_last_column
    run = Reference.new.run(program do
      game_loop { draw_column_at :bars, slice: 99, x: 10, top: 0, height: 4 }
    end, frames: 2)

    assert_equal %i[red green blue white], column_on_screen(run, 10, 0, 4)
  end

  def test_a_picture_that_does_not_exist_says_how_to_make_one
    err = assert_raises(ArgumentError) do
      program { game_loop { draw_column_at :nope, slice: 0, x: 0, top: 0, height: 4 } }
    end

    assert_match(/image :nope/, err.message)
  end

  # The two backends have to land every pixel in the same place, or the interpreter is no use
  # for debugging a renderer built on this.
  def test_the_console_draws_the_same_pixels_as_the_interpreter
    prog = program do
      tall = var :tall, 0
      game_loop do
        tall.set 40
        draw_column_at :bars, slice: 0, x: 10, top: 10, height: tall
        draw_column_at :bars, slice: 1, x: 12, top: 10, height: 2
        draw_column_at :bars, slice: 0, x: 14, top: 10, height: 0
        draw_column_at :bars, slice: 0, x: 16, top: -8, height: 24
        draw_column_at :bars, slice: 0, x: 18, top: 150, height: 40
        draw_column_at :bars, slice: 9, x: 20, top: 10, height: 8
      end
    end

    interp = Reference.new.run(prog, frames: 2)
    rom = ROM.assemble(GBA.new.lower(prog), title: "COLUMN", code: "ACOL", maker: "01")
    gba = assert_gemba_loads_rom(rom, frames: 4)

    differ = (0...240).to_a.product((0...160).to_a).reject do |x, y|
      interp.screen.pixel(x, y) == gba.pixel_gba(x, y)
    end

    assert_empty differ.first(8), "these pixels differ between the interpreter and the console"
  end
end
