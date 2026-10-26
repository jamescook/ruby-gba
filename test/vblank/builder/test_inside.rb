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

  # --- what it draws ---------------------------------------------------------------

  def test_a_fill_stops_at_the_edges_of_the_area
    run = game_player.run(program do
      game_loop do
        clear_screen :black
        inside(*AREA) { dma_fill_rect 0, 0, 240, 160, :red }
      end
    end, frames: 2)

    red = VBlank::Graphics::Color.resolve(:red)
    wrong = every_pixel.reject { |x, y| (run.screen.pixel(x, y) == red) == inside?(x, y) }

    assert_empty wrong.first(8), "red should be exactly the area and nothing else"
  end

  # Drawing outside the block is untouched by it, which is the whole point: a panel goes there.
  def test_drawing_after_the_block_is_not_held_to_the_area
    run = game_player.run(program do
      game_loop do
        clear_screen :black
        inside(*AREA) { dma_fill_rect 0, 0, 240, 160, :red }
        dma_fill_rect 0, 120, 240, 20, :blue
      end
    end, frames: 2)

    assert_equal VBlank::Graphics::Color.resolve(:blue), run.screen.pixel(4, 130),
                 "the panel is outside the area and draws"
  end

  # A routine with an area of its own, called from inside another: when it returns, the
  # caller's area is still in force, not "anywhere". The console has the caller's edges
  # baked into every shape after the call, so the interpreter dropping them would put the
  # two at odds on exactly the pattern the guardrail steers people toward.
  def test_a_routines_own_area_gives_the_callers_back_when_it_returns
    run = game_player.run(program do
      func(:paint) { inside(0, 0, 60, 60) { dma_fill_rect 0, 0, 240, 160, :green } }
      game_loop do
        clear_screen :black
        inside(*AREA) do
          call :paint
          dma_fill_rect 0, 0, 240, 160, :red
        end
      end
    end, frames: 2)

    assert_equal VBlank::Graphics::Color.resolve(:green), run.screen.pixel(10, 10), "the routine's own area held"
    assert_equal VBlank::Graphics::Color.resolve(:red), run.screen.pixel(50, 30), "the caller's area is painted after it"
    assert_equal VBlank::Graphics::Color.resolve(:black), run.screen.pixel(150, 120),
                 "and the caller's edges are back in force for the fill that followed the call"
  end

  # --- and the console draws the same ----------------------------------------------

  # AN AREA HOLDS DRAWING, NOT THE DISPLAY. A game whose frames end while an area is open shows
  # the whole picture all the same — the area only says where drawing may land — and a window
  # moved over the picture moves over all of it. The picture is read at a frame boundary, while
  # the area is still open, and compared with the console's whole: the window stands still, so
  # every frame shows the same picture. Inside the area's right edge the window shows cells from
  # outside it, and outside the area it shows the red square moved by the window.
  def test_the_whole_picture_shows_while_a_frame_ends_inside_an_area
    prog = program do
      clear_screen :blue
      fill_rect 0, 0, 20, 20, :red
      inside(*AREA) { game_loop { camera 6, 0 } }
    end
    seen = nil
    interp = game_player
    interp.each_vblank { |frame| seen = interp.screen.shown if frame == 3 }.run(prog, frames: 3)
    rom = ROM.assemble(GBA.new.lower(prog), title: "INSIDE3", code: "AIN3", maker: "01")
    console = assert_emulator_loads_rom(rom, frames: 6)

    assert_equal VBlank::Graphics::Color.resolve(:red), seen[(10 * 240) + 4], "outside the area, moved by the window"
    differ = every_pixel.reject { |x, y| seen[(y * 240) + x] == console.pixel_gba(x, y) }
    assert_empty differ.first(8), "read at a frame boundary inside the area, these pixels differ from the console"
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
end
