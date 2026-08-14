# frozen_string_literal: true

require "test_helper"
require "differential"

# A PART OF THE SCREEN THAT DRAWING STAYS INSIDE.
#
# What makes it worth having is not that the picture comes out right — a game could paint a
# panel over the top afterwards and get the same picture. It is that the pixels outside are
# never worked out, so a game with a panel stops paying for the world it draws underneath it.
# That cannot be read off a screen, so it is measured separately at the end.
#
# The two backends reach the answer in completely different ways: the interpreter asks one
# question at the one place a cell is painted, and the console works the same edges out again
# inside every shape. So the two agreeing over the whole screen is the proof.
class TestInside < Minitest::Test
  include GembaSupport

  BARS = %i[red red green green blue blue white white].freeze
  AREA = [40, 20, 120, 80].freeze # x, y, w, h — off every edge of the screen

  def program(mode: :bitmap, tear_free: false, &block)
    b = Builder.new
    colours = tear_free ? [:black, :red, :green, :blue, :white, :yellow] : nil
    b.instance_eval do
      tear_free ? (screen mode, tear_free: true, colors: colours) : (screen mode)
      image :bars, width: 2, height: 4, data: BARS
    end
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  def inside?(x, y)
    ax, ay, aw, ah = AREA
    x >= ax && x < ax + aw && y >= ay && y < ay + ah
  end

  # --- what it draws ---------------------------------------------------------------

  def test_a_fill_stops_at_the_edges_of_the_area
    run = Reference.new.run(program do
      game_loop do
        clear_screen :black
        inside(*AREA) { dma_fill_rect 0, 0, 240, 160, :red }
      end
    end, frames: 2)

    red = RubyGBA::Color.resolve(:red)
    wrong = every_pixel.reject { |x, y| (run.screen.pixel(x, y) == red) == inside?(x, y) }

    assert_empty wrong.first(8), "red should be exactly the area and nothing else"
  end

  # A stretched column is the one this exists for: it is the verb whose height a game works out,
  # so it is the one that draws far past an edge and pays for every row of it.
  def test_a_stretched_column_stops_at_the_edges_of_the_area
    run = Reference.new.run(program do
      game_loop do
        clear_screen :black
        inside(*AREA) do
          (0...240).step(4) { |x| draw_column_at :bars, slice: 0, x: x, top: -40, height: 240 }
        end
      end
    end, frames: 2)

    painted = every_pixel.select { |x, y| run.screen.pixel(x, y) != RubyGBA::Color.resolve(:black) }

    refute_empty painted, "the columns should draw something"
    assert_empty painted.reject { |x, y| inside?(x, y) }.first(8), "and nothing outside the area"
  end

  # Drawing outside the block is untouched by it, which is the whole point: a panel goes there.
  def test_drawing_after_the_block_is_not_held_to_the_area
    run = Reference.new.run(program do
      game_loop do
        clear_screen :black
        inside(*AREA) { dma_fill_rect 0, 0, 240, 160, :red }
        dma_fill_rect 0, 140, 240, 20, :blue
      end
    end, frames: 2)

    assert_equal RubyGBA::Color.resolve(:blue), run.screen.pixel(4, 150),
                 "the panel is outside the area and draws"
  end

  # An area CLIPS, it does not move: a pixel keeps the coordinates it was given, so an area can
  # be put around drawing that already works and only what fell outside changes.
  def test_an_area_does_not_move_what_it_keeps
    plain = program { game_loop { draw_column_at :bars, slice: 0, x: 100, top: 40, height: 32 } }
    held = program do
      game_loop { inside(*AREA) { draw_column_at :bars, slice: 0, x: 100, top: 40, height: 32 } }
    end

    one = Reference.new.run(plain, frames: 2)
    two = Reference.new.run(held, frames: 2)
    differ = every_pixel.reject { |x, y| one.screen.pixel(x, y) == two.screen.pixel(x, y) }

    assert_empty differ.first(8), "a shape wholly inside the area draws exactly where it did"
  end

  # --- and the console draws the same ----------------------------------------------

  # KEPT LIGHT ON PURPOSE. This screen is drawn straight into the one the console is showing, so
  # a frame that takes longer than a frame is read half finished — and since the drawing runs
  # left to right, what that looks like is the right-hand side disagreeing. That is a measure of
  # how far the console GOT, not of what it draws, and it will happily fail a correct backend.
  # A dozen short columns finish inside a frame with room to spare.
  def test_the_console_clips_where_the_interpreter_clips
    prog = program do
      tall = var :tall, 0
      game_loop do
        clear_screen :black
        tall.set 90
        inside(*AREA) do
          dma_fill_rect 0, 0, 240, 160, :green
          (0...240).step(20) { |x| draw_column_at :bars, slice: 0, x: x, top: -20, height: tall }
          draw_column_at :bars, slice: 1, x: 38, top: 0, height: 60, width: 4
          draw_column_at :bars, slice: 1, x: 156, top: 0, height: 60, width: 4
          fill_rect 0, 0, 240, 8, :white
          pixel 10, 10, :blue
          pixel 100, 100, :blue
        end
        dma_fill_rect 0, 150, 240, 10, :blue
      end
    end

    assert_backends_agree(prog, "INSIDE", "AIN1")
  end

  # ...and on the tear-free screen, which is a different lowering with its own clipping and the
  # one a first-person view actually draws on.
  def test_the_tear_free_console_clips_where_the_interpreter_clips
    prog = program(tear_free: true) do
      tall = var :tall, 0
      game_loop do
        tall.set 240
        inside(*AREA) do
          dma_fill_rect 0, 0, 240, 160, :green
          (0...240).step(6) { |x| draw_column_at :bars, slice: 0, x: x, top: -40, height: tall }
          draw_column_at :bars, slice: 1, x: 38, top: 0, height: 60, width: 4
          draw_column_at :bars, slice: 1, x: 156, top: 0, height: 60, width: 4
        end
        dma_fill_rect 0, 150, 240, 10, :blue
      end
    end

    assert_backends_agree(prog, "INSIDE2", "AIN2")
  end

  # --- the friendly errors ---------------------------------------------------------

  def test_an_area_worked_out_as_the_game_runs_is_refused
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        edge = var :edge, 100
        inside(0, 0, 240, edge) { pixel 1, 1, :red }
      end
    end

    assert_match(/settled while you build/, err.message)
  end

  def test_one_area_inside_another_is_refused
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        inside(0, 0, 240, 128) { inside(0, 0, 100, 100) { pixel 1, 1, :red } }
      end
    end

    assert_match(/cannot go inside another/, err.message)
  end

  private

  def every_pixel = @every_pixel ||= (0...240).to_a.product((0...160).to_a)

  def assert_backends_agree(prog, title, code)
    interp = Reference.new.run(prog, frames: 3)
    rom = ROM.assemble(GBA.new.lower(prog), title: title, code: code, maker: "01")
    gba = assert_gemba_loads_rom(rom, frames: 6)

    differ = every_pixel.reject { |x, y| (interp.screen.pixel(x, y) || 0) == gba.pixel_gba(x, y) }

    assert_empty differ.first(8), "these pixels differ between the interpreter and the console"
  end
end
