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

  # The bar's width in frames: how many WIDE-wide blocks of white are on that row.
  def reading(screen_pixel, row: 4)
    white = RubyGBA::Color.resolve(:white)
    lit = (0...240).count { |x| screen_pixel.call(x, row) == white }
    lit / WIDE
  end

  def test_the_interpreter_is_never_late_so_it_always_answers_one
    run = Reference.new.run(program(0), frames: 4)

    assert_equal 1, reading(->(x, y) { run.screen.pixel(x, y) })
  end

  def test_a_game_that_fits_in_a_frame_answers_one_on_the_console
    rom = ROM.assemble(GBA.new.lower(program(0)), title: "STEP1", code: "AST1", maker: "01")
    gba = assert_emulator_loads_rom(rom, frames: 8)

    assert_equal 1, reading(->(x, y) { gba.pixel_gba(x, y) })
  end

  # THE ONE THAT MATTERS. Burn past a frame's worth of work, and the pass has to answer for more
  # than one frame. Measured while writing this: burning nothing reads 1, this reads 2, four
  # times as much reads 7 — so it counts rather than merely noticing.
  def test_a_pass_that_overruns_a_frame_says_so_on_the_console
    rom = ROM.assemble(GBA.new.lower(program(30_000)), title: "STEP2", code: "AST2", maker: "01")
    gba = assert_emulator_loads_rom(rom, frames: 40)
    counted = reading(->(x, y) { gba.pixel_gba(x, y) })

    assert_operator counted, :>=, 2, "a pass that cannot finish inside a frame counts more than one"
    assert_operator counted, :<, Frames::MOST, "...and this one is counting, not being held"
  end

  # --- and what reads it -----------------------------------------------------------

  # A `once_a_frame` body is run once for each frame that really passed, which is the whole of
  # the promise its name makes. Both numbers are drawn — how many frames the pass took, and how
  # many times the body ran — so the test says they AGREE rather than merely that the body ran
  # more than once.
  def counting_program(busy)
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      step = RubyGBA::Value.new(self, RubyGBA::IR::Build.var_ref(Frames::STEP))
      ticks = var :ticks, 0
      last = var :last, 0
      loops = var :loops, 0
      spin = var :spin, 0
      once_a_frame { ticks.add 1 }
      game_loop do
        loops.add 1 # ...which the loop body does once a PASS, however many frames that took
        dma_fill_rect 0, 0, 240, 24, :black
        draw_rect_at 0, 0, step * WIDE, 8, :white
        draw_rect_at 0, 12, (ticks - last) * WIDE, 8, :white
        last.set ticks
        repeat(busy) { spin.add 1 } if busy.positive?
      end
    end
    b.emit_pending_functions
    b.program
  end

  def test_a_once_a_frame_body_runs_once_per_frame_on_a_game_that_keeps_up
    run = Reference.new.run(counting_program(0), frames: 4)
    pixel = ->(x, y) { run.screen.pixel(x, y) }

    assert_equal 1, reading(pixel), "one frame a pass"
    assert_equal 1, reading(pixel, row: 16), "...and the body ran once"
    assert_equal run[:loops], run[:ticks], "and on a game that keeps up, the two agree exactly"
  end

  def test_a_once_a_frame_body_runs_again_for_each_frame_a_late_pass_took
    rom = ROM.assemble(GBA.new.lower(counting_program(30_000)), title: "OAF", code: "AOAF", maker: "01")
    gba = assert_emulator_loads_rom(rom, frames: 40)
    pixel = ->(x, y) { gba.pixel_gba(x, y) }

    assert_operator reading(pixel), :>=, 2, "the pass should have taken more than one frame"
    assert_equal reading(pixel), reading(pixel, row: 16),
                 "the body should run once for each frame the pass took"
  end

  # --- and what the oracle can be TOLD ---------------------------------------------

  # THE INTERPRETER HAS NO CLOCK, so a test says how late a pass ran instead of it finding out.
  # That is what makes everything a program does about being late checkable in-process, where
  # before it could only be seen by burning a console past a frame and reading the screen.
  def test_the_interpreter_answers_what_a_test_says_a_pass_was_worth
    run = Reference.new.frames_each_pass { 3 }.run(counting_program(0), frames: 4)
    pixel = ->(x, y) { run.screen.pixel(x, y) }

    assert_equal 3, reading(pixel), "the pass answered for three frames"
    assert_equal 3, reading(pixel, row: 16), "...so the body ran three times"
    assert_equal run[:loops] * 3, run[:ticks], "three frames a pass, all the way through"
  end

  # ...and it is held at the same cap the console holds it at, so a body asked to catch up can
  # never be asked to catch up further here than it would there.
  def test_a_test_that_says_something_wild_is_held_at_the_cap
    run = Reference.new.frames_each_pass { 500 }.run(counting_program(0), frames: 3)

    assert_equal Frames::MOST, reading(->(x, y) { run.screen.pixel(x, y) })
  end

  # A pass can be late once and not again, which is what a hitch is — and the number is read
  # per pass, not fixed for the run.
  def test_lateness_is_answered_pass_by_pass
    run = Reference.new.frames_each_pass { |pass| pass == 2 ? 4 : 1 }
                       .run(counting_program(0), frames: 4)

    assert_equal 4 + 3, run[:ticks], "one pass worth four frames, three worth one each"
    assert_equal 4, run[:loops], "...over four passes of the loop"
  end

  # THE WHOLE THESIS IN TWO NUMBERS. The same movement, written the two ways round, on a game
  # whose every pass takes three frames: written in the game loop it moves once a PASS, so the
  # world runs at a third speed and the game is in slow motion; written in `once_a_frame` it
  # moves once a FRAME, so it keeps real time and what a slow game costs is a jerkier picture.
  # Neither is a bug — the choice is the author's — but they are different games.
  def slow_motion_or_choppy
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      by_pass = var :by_pass, 0
      by_clock = var :by_clock, 0
      once_a_frame { by_clock.add 1 }
      game_loop { by_pass.add 1 }
    end
    b.emit_pending_functions
    b.program
  end

  def test_movement_on_the_clock_keeps_real_time_where_movement_in_the_loop_does_not
    run = Reference.new.frames_each_pass { 3 }.run(slow_motion_or_choppy, frames: 5)

    assert_equal 5, run[:by_pass], "five passes, so five steps — a third of the way in real time"
    assert_equal 15, run[:by_clock], "fifteen frames really went by, and it moved on every one"
  end

  # A BEAT GIVEN IN FRAMES IS FRAMES, not passes of the game loop. This is the one that used to
  # be wrong, and the one an author would never have found: they wrote `every(4)`, the game got
  # heavy, and the beat quietly slowed down with it.
  #
  # A game burning past a frame is run long enough for several beats, and the test asks whether
  # the number of beats matches the number of FRAMES rather than the number of passes.
  def beating_program(busy, period)
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      step = RubyGBA::Value.new(self, RubyGBA::IR::Build.var_ref(Frames::STEP))
      beats = var :beats, 0
      spin = var :spin, 0
      game_loop do
        every(period) { beats.add 1 }
        dma_fill_rect 0, 0, 240, 24, :black
        draw_rect_at 0, 0, step * WIDE, 8, :white
        draw_rect_at 0, 12, beats * WIDE, 8, :white
        repeat(busy) { spin.add 1 } if busy.positive?
      end
    end
    b.emit_pending_functions
    b.program
  end

  # Six frames a pass and a beat every four frames: after four passes that is 24 frames, so six
  # beats. Counted per PASS it would be one. The exact numbers are read off the screen rather
  # than assumed, since how late a pass runs is the console's business.
  def test_a_beat_in_frames_keeps_time_when_the_game_does_not
    rom = ROM.assemble(GBA.new.lower(beating_program(90_000, 4)), title: "BEAT", code: "ABEA", maker: "01")
    gba = assert_emulator_loads_rom(rom, frames: 40)
    pixel = ->(x, y) { gba.pixel_gba(x, y) }
    late = reading(pixel)
    beats = reading(pixel, row: 16)

    assert_operator late, :>=, 2, "the pass should have taken more than one frame"
    assert_operator beats, :>=, late / 4, "the beat should have kept up with the frames, not the passes"
    assert_operator beats, :>, 1, "counted per pass it would still be on its first beat"
  end

  # A ONE-SHOT MUST STILL GO OFF WHEN THE PASS STEPS OVER ITS FRAME. Counting one a pass, the
  # counter landed on the target exactly and firing on equality was safe. Counting frames, a pass
  # worth six can take a counter from nought straight past five — so a one-shot that waited for
  # equality would wait for ever, which is the worst way for this to fail: silently, and only on
  # the games too heavy to test by eye.
  def one_shot_program(busy, wait)
    b = RubyGBA::Builder.new
    b.instance_eval do
      screen :bitmap
      fired = var :fired, 0
      spin = var :spin, 0
      game_loop do
        after(wait) { fired.set 1 }
        dma_fill_rect 0, 0, 240, 24, :black
        draw_rect_at 0, 12, fired * WIDE, 8, :white
        repeat(busy) { spin.add 1 } if busy.positive?
      end
    end
    b.emit_pending_functions
    b.program
  end

  def test_a_one_shot_fires_even_when_a_pass_steps_over_its_frame
    rom = ROM.assemble(GBA.new.lower(one_shot_program(90_000, 5)), title: "ONCE", code: "AONC", maker: "01")
    gba = assert_emulator_loads_rom(rom, frames: 40)

    assert_equal 1, reading(->(x, y) { gba.pixel_gba(x, y) }, row: 16),
                 "a pass worth several frames jumps the counter past five, and it must still fire"
  end

  # ...and a pass that took a very long time is held, so that whatever reads this is never asked
  # to do half a second of catching up inside one already-late pass.
  def test_a_very_long_pass_is_held_at_the_cap
    rom = ROM.assemble(GBA.new.lower(program(400_000)), title: "STEP3", code: "AST3", maker: "01")
    gba = assert_emulator_loads_rom(rom, frames: 70)

    assert_equal Frames::MOST, reading(->(x, y) { gba.pixel_gba(x, y) }),
                 "a pass this long should be held at the cap, not counted whole"
  end
end
