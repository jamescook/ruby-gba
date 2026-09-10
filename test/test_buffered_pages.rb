# frozen_string_literal: true

require "test_helper"
require "differential"

# THE TWO PAGES OF A TEAR-FREE SCREEN, and what a program can see of them.
#
# `screen :bitmap, tear_free: true` is not one picture but two. The display shows
# one of them while the program draws into the other, and they trade places at the
# frame boundary — which is exactly why the player never catches a half-drawn
# picture, since nothing is ever drawn into the page being looked at.
#
# The price is that a frame's drawing lands on ONE of the two. A program that
# repaints everything every frame never notices, because both pages come out
# holding a complete picture; a program that ADDS to what is already there puts
# half its additions on each page. That difference is invisible in the source and
# obvious on the console, which is what makes it worth a test file of its own.
#
# Every expectation here was measured on the console FIRST and the interpreter made
# to agree, not the other way round — including which half of the bars survive.
class TestBufferedPages < Minitest::Test
  include Differential
  include GembaSupport

  BAR_ROW = 50
  BARS = 10

  # Cleared once, then one bar added per frame and never repainted. The shape of a
  # dissolve, a trail, a plot filling in — anything that builds a picture up over
  # several frames instead of redrawing it.
  def adding_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      clear_screen :black
      n = var :n, 0
      game_loop do
        draw_rect_at n * 20, 4, 8, 100, :red
        n.add 1
      end
    end
    b.emit_pending_functions
    b.program
  end

  # Which of the ten bars a finished picture actually holds.
  def bars_shown(pixels)
    red = Color.resolve(:red)
    (0...BARS).select { |k| pixels[(BAR_ROW * 240) + (k * 20) + 3] == red }
  end

  # THE ONE THAT MATTERS. Ten frames, ten bars drawn, and only five on screen —
  # because the other five are sitting on the page nobody is looking at. Before the
  # interpreter modelled the pages it said all ten, so a test asserting ten passed
  # while the cartridge showed five.
  #
  # The PARITY is asserted, not just the count: a page model off by one frame also
  # gives five bars, and gives the wrong five.
  def test_a_program_that_adds_lands_half_its_drawing_on_each_page
    i = Reference.new.run(adding_program, frames: BARS)
    assert_equal [1, 3, 5, 7, 9], bars_shown(i.screen.to_a),
                 "every other bar is on the page being shown; the rest are on the other one"
  end

  # ...and the console says the same thing, pixel for pixel over the whole screen.
  def test_the_console_agrees_about_which_half_survives
    assert_backends_agree(adding_program, frames: BARS)
  end

  # The other half of the bargain, and why this went unnoticed so long: a program
  # that repaints every frame draws a complete picture onto whichever page it gets,
  # so both pages agree and the split is invisible.
  def test_a_program_that_repaints_sees_no_difference_at_all
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      game_loop do
        clear_screen :red
        fill_rect 100, 60, 40, 40, :blue
      end
    end
    b.emit_pending_functions
    prog = b.program

    i = Reference.new.run(prog, frames: BARS)
    assert_equal Color.resolve(:red), i.screen.pixel(10, 10)
    assert_equal Color.resolve(:blue), i.screen.pixel(120, 80)
    assert_backends_agree(prog, frames: BARS)
  end

  # A program that draws and never reaches a frame boundary shows NOTHING: the
  # console boots showing page 0 and hands the program page 1, so without a flip
  # the drawing is all on the hidden page. Measured on the console, where this
  # program is a black screen.
  def test_drawing_with_no_frame_boundary_shows_nothing
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      clear_screen :red
      fill_rect 100, 60, 40, 40, :blue
      halt
    end
    b.emit_pending_functions
    prog = b.program

    i = Reference.new.run(prog)
    assert_equal 0, i.screen.pixel(10, 10), "the drawing is on the page nobody is looking at"
    assert_equal 0, i.screen.pixel(120, 80)

    rom = ROM.assemble(GBA.new.lower(prog), title: "NOFLIP", code: "NOFL", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)
    assert_equal 0, v.pixel_gba(10, 10), "and the console shows the same blank page"
    assert_equal 0, v.pixel_gba(120, 80)
  end

  # A single flip presents it — the pairing that makes the rule legible, and the
  # reason the IR-level buffered tests all end in wait_vblank.
  def test_one_frame_boundary_presents_the_page
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      clear_screen :red
      wait_vblank
      halt
    end
    b.emit_pending_functions

    i = Reference.new.run(b.program)
    assert_equal Color.resolve(:red), i.screen.pixel(10, 10)
  end

  # A single-buffered screen has one page, so nothing above applies to it: the same
  # adding program keeps every bar. This is what pins the page model to the
  # tear-free screen rather than leaking into the plain one.
  def test_a_plain_bitmap_screen_keeps_every_bar
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      n = var :n, 0
      game_loop do
        draw_rect_at n * 20, 4, 8, 100, :red
        n.add 1
      end
    end
    b.emit_pending_functions

    i = Reference.new.run(b.program, frames: BARS)
    assert_equal (0...BARS).to_a, bars_shown(i.screen.to_a)
  end
end
