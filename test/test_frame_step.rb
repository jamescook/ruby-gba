# frozen_string_literal: true

require "test_helper"

# HOW MANY FRAMES A PASS OF THE GAME LOOP REALLY TOOK.
#
# A game that fits in a frame answers one every time, and that is nearly every game — so most of
# what is pinned here is that nothing changed for them. The answer that matters is the other one:
# a game whose pass overruns has to say so, and only the console can be asked, because the
# interpreter has no clock and is never late by construction.
#
# The number is read off the SCREEN rather than out of memory, as a bar so many pixels wide, so
# that what is tested is what a game would actually get.
class TestFrameStep < Minitest::Test
  Frames = RubyGBA::IR::Backends::GBA::Frames
  WIDE = 8 # pixels of bar per frame counted, so the reading is legible and hard to misread

  # A game loop that shows the count as a bar and THEN burns +busy+ passes of an empty loop.
  # Enough burning and the pass cannot finish inside one frame.
  #
  # The bar is drawn FIRST and only its own rows are cleared, which matters on this screen: it is
  # drawn straight into the one being shown, so a test that cleared the screen and burned before
  # drawing would be read black nearly every time. This way the answer is on screen for all but a
  # sliver of each pass.
  def program(busy)
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      step = RubyGBA::Value.new(self, RubyGBA::IR::Build.var_ref(Frames::STEP))
      spin = var :spin, 0
      game_loop do
        dma_fill_rect 0, 0, 240, 8, :black
        draw_rect_at 0, 0, step * WIDE, 8, :white
        repeat(busy) { spin.add 1 } if busy.positive?
      end
    end
    b.emit_pending_functions
    b.program
  end

  # The bar's width in frames: how many WIDE-wide blocks of white are on the top row.
  def reading(screen_pixel)
    white = RubyGBA::Color.resolve(:white)
    lit = (0...240).count { |x| screen_pixel.call(x, 4) == white }
    lit / WIDE
  end

  def test_the_interpreter_is_never_late_so_it_always_answers_one
    run = Reference.new.run(program(0), frames: 4)

    assert_equal 1, reading(->(x, y) { run.screen.pixel(x, y) })
  end

  def test_a_game_that_fits_in_a_frame_answers_one_on_the_console
    rom = ROM.assemble(GBA.new.lower(program(0)), title: "STEP1", code: "AST1", maker: "01")
    gba = assert_gemba_loads_rom(rom, frames: 8)

    assert_equal 1, reading(->(x, y) { gba.pixel_gba(x, y) })
  end

  # THE ONE THAT MATTERS. Burn past a frame's worth of work, and the pass has to answer for more
  # than one frame. Measured while writing this: burning nothing reads 1, this reads 2, four
  # times as much reads 7 — so it counts rather than merely noticing.
  def test_a_pass_that_overruns_a_frame_says_so_on_the_console
    rom = ROM.assemble(GBA.new.lower(program(30_000)), title: "STEP2", code: "AST2", maker: "01")
    gba = assert_gemba_loads_rom(rom, frames: 40)
    counted = reading(->(x, y) { gba.pixel_gba(x, y) })

    assert_operator counted, :>=, 2, "a pass that cannot finish inside a frame counts more than one"
    assert_operator counted, :<, Frames::MOST, "...and this one is counting, not being held"
  end

  # ...and a pass that took a very long time is held, so that whatever reads this is never asked
  # to do half a second of catching up inside one already-late pass.
  def test_a_very_long_pass_is_held_at_the_cap
    rom = ROM.assemble(GBA.new.lower(program(400_000)), title: "STEP3", code: "AST3", maker: "01")
    gba = assert_gemba_loads_rom(rom, frames: 70)

    assert_equal Frames::MOST, reading(->(x, y) { gba.pixel_gba(x, y) }),
                 "a pass this long should be held at the cap, not counted whole"
  end
end
