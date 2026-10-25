# frozen_string_literal: true

require "test_helper"

# The tests of test_inside.rb whose games paint more colours into one 8×8 square of the screen
# than a Game Boy Color's square holds (four, black among them), so they play on the Advance's
# runs alone.
class TestInsideOnTheAdvance < Minitest::Test
  include EmulatorSupport

  BARS = %i[red red green green blue blue white white].freeze
  AREA = [40, 20, 120, 80].freeze # x, y, w, h — off every edge of the screen

  private def program(mode: :bitmap, tear_free: false, &block)
    b = Builder.new
    colours = tear_free ? [:black, :red, :green, :blue, :white, :yellow] : nil
    b.instance_eval do
      tear_free ? (screen mode, tear_free: true, colors: colours) : (screen mode)
      image :bars, width: 2, height: 4, data: BARS
    end
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  private def inside?(x, y)
    ax, ay, aw, ah = AREA
    x >= ax && x < ax + aw && y >= ay && y < ay + ah
  end

  # A stretched column is the one this exists for: it is the verb whose height a game works out,
  # so it is the one that draws far past an edge and pays for every row of it.
  def test_a_stretched_column_stops_at_the_edges_of_the_area
    run = game_player.run(program do
      game_loop do
        clear_screen :black
        inside(*AREA) do
          (0...240).step(4) { |x| draw_column_at :bars, slice: 0, x: x, top: -40, height: 240 }
        end
      end
    end, frames: 2)

    painted = every_pixel.select { |x, y| run.screen.pixel(x, y) != RubyGBA::Graphics::Color.resolve(:black) }

    refute_empty painted, "the columns should draw something"
    assert_empty painted.reject { |x, y| inside?(x, y) }.first(8), "and nothing outside the area"
  end

  # An area CLIPS, it does not move: a pixel keeps the coordinates it was given, so an area can
  # be put around drawing that already works and only what fell outside changes.
  def test_an_area_does_not_move_what_it_keeps
    plain = program { game_loop { draw_column_at :bars, slice: 0, x: 100, top: 40, height: 32 } }
    held = program do
      game_loop { inside(*AREA) { draw_column_at :bars, slice: 0, x: 100, top: 40, height: 32 } }
    end

    one = game_player.run(plain, frames: 2)
    two = game_player.run(held, frames: 2)
    differ = every_pixel.reject { |x, y| one.screen.pixel(x, y) == two.screen.pixel(x, y) }

    assert_empty differ.first(8), "a shape wholly inside the area draws exactly where it did"
  end

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
        tall.set! 90
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
        tall.set! 240
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

  private def every_pixel = @every_pixel ||= (0...240).to_a.product((0...160).to_a)

  private def assert_backends_agree(prog, title, code)
    interp = game_player.run(prog, frames: 3)
    rom = ROM.assemble(GBA.new.lower(prog), title: title, code: code, maker: "01")
    gba = assert_emulator_loads_rom(rom, frames: 6)

    differ = every_pixel.reject { |x, y| (interp.screen.pixel(x, y) || 0) == gba.pixel_gba(x, y) }

    assert_empty differ.first(8), "these pixels differ between the interpreter and the console"
  end
end
