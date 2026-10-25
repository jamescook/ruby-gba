# frozen_string_literal: true

require "test_helper"

# The tests of test_draw_column_at.rb whose games paint more colours into one 8×8 square of the
# screen than a Game Boy Color's square holds — the bars alone are four, with the screen behind
# them besides. So they play on the Advance's runs alone.
class TestDrawColumnAtOnTheAdvance < Minitest::Test
  include EmulatorSupport

  # Four rows, each its own color, so a stretch is readable row by row.
  BARS = %i[red red green green blue blue white white].freeze
  NAMES = { RubyGBA::Graphics::Color.resolve(:red) => :red, RubyGBA::Graphics::Color.resolve(:green) => :green,
            RubyGBA::Graphics::Color.resolve(:blue) => :blue, RubyGBA::Graphics::Color.resolve(:white) => :white,
            0 => nil }.freeze

  private def program(&block)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image :bars, width: 2, height: 4, data: BARS
    end
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  private def column_on_screen(run, x, from, to)
    (from...to).map { |y| NAMES.fetch(run.screen.pixel(x, y), :other) }
  end

  def test_a_column_stretched_to_twice_its_height_shows_each_row_twice
    run = game_player.run(program do
      game_loop { draw_column_at :bars, slice: 0, x: 10, top: 0, height: 8 }
    end, frames: 2)

    assert_equal %i[red red green green blue blue white white], column_on_screen(run, 10, 0, 8)
  end

  def test_a_column_squashed_to_half_its_height_drops_the_rows_between
    run = game_player.run(program do
      game_loop { draw_column_at :bars, slice: 0, x: 10, top: 0, height: 2 }
    end, frames: 2)

    assert_equal %i[red blue], column_on_screen(run, 10, 0, 2)
  end

  # A height the game works out is the whole point — a wall's height is never known while
  # building.
  def test_a_height_the_game_works_out_stretches_the_same_way
    run = game_player.run(program do
      tall = var :tall, 0
      game_loop do
        tall.set! 8
        draw_column_at :bars, slice: 0, x: 10, top: 0, height: tall
      end
    end, frames: 2)

    assert_equal %i[red red green green blue blue white white], column_on_screen(run, 10, 0, 8)
  end

  # A wall you are nose-to-nose with is taller than the screen, and one at the far end of a
  # corridor has no height at all. Neither needs a test around it.
  def test_no_height_draws_nothing_and_a_column_past_the_screen_is_clipped
    run = game_player.run(program do
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
    run = game_player.run(program do
      game_loop { draw_column_at :bars, slice: 99, x: 10, top: 0, height: 4 }
    end, frames: 2)

    assert_equal %i[red green blue white], column_on_screen(run, 10, 0, 4)
  end

  # A first-person view draws its columns in a LOOP, so this is the case that matters most, and
  # it was broken: a loop keeps its count in the console's registers unless the body needs them,
  # and a stretched column needs them twice over — it works in them, and it calls the divide
  # routine to find its step. Undeclared, the first column drew and the loop then walked off.
  def test_columns_drawn_in_a_loop_all_arrive
    prog = program do
      game_loop do
        repeat(8) { |c| draw_column_at :bars, slice: 0, x: c, top: 0, height: 4 }
      end
    end

    interp = game_player.run(prog, frames: 2)
    drawn = (0...8).count { |x| interp.screen.pixel(x, 0) == RubyGBA::Graphics::Color.resolve(:red) }
    assert_equal 8, drawn, "the interpreter should draw every column"

    rom = ROM.assemble(GBA.new.lower(prog), title: "LOOP")
    gba = assert_emulator_loads_rom(rom, frames: 4)
    on_console = (0...8).count { |x| gba.pixel_gba(x, 0) == RubyGBA::Graphics::Color.resolve(:red) }

    assert_equal 8, on_console, "the console should draw every column too"
  end

  # A depth record — what keeps a guard from showing through a wall — needs nothing new: a list
  # holds how far away each screen column ended up, and a condition gates the next draw. Worth
  # a test because it is the pattern a first-person view is built on.
  def test_a_column_can_be_gated_on_a_distance_kept_per_column
    prog = program do
      image :thing, width: 1, height: 2, data: %i[white white]
      depth = list :depth, capacity: 8
      col = var :col, 0
      repeat(8) { depth << 0 } # a list starts empty; a depth record needs its slots up front

      game_loop do
        repeat(8) do |c|
          far = var :_far, 0
          far.set! 10
          (c >= 4).then { far.set! 2 } # the right half is nearer than the thing
          depth[c] = far
          draw_column_at :bars, slice: 0, x: c, top: 0, height: 8
        end
        repeat(8) do |c|
          col.set! c
          (depth[col] > 5).then { draw_column_at :thing, slice: 0, x: col, top: 2, height: 4 }
        end
      end
    end

    run = game_player.run(prog, frames: 2)
    seen = (0...8).map { |x| run.screen.pixel(x, 3) == RubyGBA::Graphics::Color.resolve(:white) }

    assert_equal [true] * 4 + [false] * 4, seen,
                 "the thing shows over the far wall and is hidden by the near one"
  end

  # The two backends have to land every pixel in the same place, or the interpreter is no use
  # for debugging a renderer built on this.
  def test_the_console_draws_the_same_pixels_as_the_interpreter
    prog = program do
      tall = var :tall, 0
      game_loop do
        tall.set! 40
        draw_column_at :bars, slice: 0, x: 10, top: 10, height: tall
        draw_column_at :bars, slice: 1, x: 12, top: 10, height: 2
        draw_column_at :bars, slice: 0, x: 14, top: 10, height: 0
        draw_column_at :bars, slice: 0, x: 16, top: -8, height: 24
        draw_column_at :bars, slice: 0, x: 18, top: 150, height: 40
        draw_column_at :bars, slice: 9, x: 20, top: 10, height: 8
      end
    end

    interp = game_player.run(prog, frames: 2)
    rom = ROM.assemble(GBA.new.lower(prog), title: "COLUMN", code: "ACOL", maker: "01")
    gba = assert_emulator_loads_rom(rom, frames: 4)

    differ = (0...240).to_a.product((0...160).to_a).reject do |x, y|
      interp.screen.pixel(x, y) == gba.pixel_gba(x, y)
    end

    assert_empty differ.first(8), "these pixels differ between the interpreter and the console"
  end

  # A STRIP IS ONE WALK. Its pixels all show the same picture column at the same height, so
  # asking for them one at a time works the same answer out that many times over. What it
  # draws has to be identical, which is what this pins.
  def test_a_strip_draws_what_the_same_pixels_drawn_one_at_a_time_draw
    apiece = program do
      game_loop { 3.times { |dx| draw_column_at :bars, slice: 0, x: 10 + dx, top: 4, height: 8 } }
    end
    strip = program do
      game_loop { draw_column_at :bars, slice: 0, x: 10, top: 4, height: 8, width: 3 }
    end

    one = game_player.run(apiece, frames: 2)
    many = game_player.run(strip, frames: 2)
    differ = (0...240).to_a.product((0...160).to_a).reject do |x, y|
      one.screen.pixel(x, y) == many.screen.pixel(x, y)
    end

    assert_empty differ.first(8), "a strip drew something different from its own pixels"
    assert_equal %i[red red green green blue blue white white], column_on_screen(many, 12, 4, 12)
  end

  # A strip hanging off the side of the screen keeps the part that is on it. This is the case
  # a first-person view meets only at the edges, and the one a shared walk could quietly get
  # wrong by drawing the whole strip or none of it.
  def test_a_strip_past_the_edge_keeps_the_part_that_is_on_screen
    run = game_player.run(program do
      game_loop do
        draw_column_at :bars, slice: 0, x: 238, top: 0, height: 4, width: 4
        draw_column_at :bars, slice: 0, x: -2, top: 0, height: 4, width: 4
      end
    end, frames: 2)

    assert_equal :red, column_on_screen(run, 239, 0, 1).first, "the pixel still on screen draws"
    assert_equal :red, column_on_screen(run, 0, 0, 1).first, "and at the other edge too"
    assert_nil run.screen.pixel(240, 0), "nothing past the right edge"
  end
end
