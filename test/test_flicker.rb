# frozen_string_literal: true

require "test_helper"

# {Flicker} — is half a tear-free game's drawing being lost?
#
# The rule itself is a pure comparison of four pictures, so it is tested here as
# one, at every shape that matters. The pictures are tiny; the rule does not care
# how big they are.
class TestFlickerRule < Minitest::Test
  Flicker = RubyGBA::Flicker

  W = 8
  H = 8
  SIZE = W * H

  def blank = Array.new(SIZE, 0)

  # A picture with +count+ pixels set to +ink+, starting at +from+.
  def marked(count, ink: 1, from: 0)
    blank.tap { |px| count.times { |i| px[from + i] = ink } }
  end

  def read(before, after) = Flicker.read(before, after, width: W)

  # THE BUG. Two pictures that disagree, and neither of them moves: a dissolve
  # whose dots went half to each. Nothing is coming to fix those pixels.
  def test_two_pictures_stuck_apart_are_reported
    a = marked(40)
    b = blank
    reading = read([a, b], [a.dup, b.dup])

    assert_predicate reading, :losing?
    assert_equal 40, reading.pixels
    assert_equal [0, 0], reading.first
  end

  # A game that repaints every frame: each picture is redrawn, so both change
  # between the two boundaries even though they disagree at any instant.
  def test_a_repainting_game_is_not_reported
    before = [marked(40, ink: 1), marked(40, ink: 2)]
    after  = [marked(40, ink: 3), marked(40, ink: 4)]

    refute_predicate read(before, after), :losing?
  end

  # A still picture: the two agree, so there is nothing to disagree about.
  def test_a_still_picture_is_not_reported
    same = marked(40)
    refute_predicate read([same, same.dup], [same.dup, same.dup]), :losing?
  end

  # THE ONE A BUILD-TIME CHECK CANNOT DO. A change painted into BOTH pictures —
  # what `keep_showing` does, and what wolf3d's fizzle does with two walkers —
  # converges. The second snapshot has them agreeing, so nothing is reported.
  def test_a_change_painted_into_both_pictures_is_not_reported
    behind = marked(40)
    ahead = blank
    # ...and one frame later the other picture catches up.
    refute_predicate read([behind, ahead], [behind.dup, marked(40)]), :losing?
  end

  # A TRAIL. The drawing moved on and only one picture followed it, so the pixels
  # it left behind are stuck in the other one. Over a two-frame window both
  # pictures have had their turn, so a picture that did not follow has declined
  # to — which is the whole reason the window is two frames and not one.
  #
  # The pixels the drawing has left (0..7) and the ones it has just reached
  # (40..47) both changed, so neither is stuck; the 32 in between are.
  def test_a_drawing_that_moves_on_leaves_stuck_pixels_behind
    reading = read([marked(40), blank], [marked(40, from: 8), blank])

    assert_predicate reading, :losing?
    assert_equal 32, reading.pixels
  end

  # A stray pixel or two is not worth a line.
  def test_a_handful_of_stuck_pixels_is_below_the_floor
    a = marked(Flicker::FLOOR - 1)
    refute_predicate read([a, blank], [a.dup, blank]), :losing?
  end

  def test_at_the_floor_it_is_reported
    a = marked(Flicker::FLOOR)
    assert_predicate read([a, blank], [a.dup, blank]), :losing?
  end

  # Where to look, so a person has somewhere to start.
  def test_it_says_where_the_first_stuck_pixel_is
    a = marked(Flicker::FLOOR, from: (3 * W) + 2)
    assert_equal [2, 3], read([a, blank], [a.dup, blank]).first
  end

  # "We did not look" must never read as "nothing was wrong".
  def test_a_reading_that_was_not_taken_says_so
    refute_predicate Flicker::Reading.none, :measured?
    refute_predicate Flicker::Reading.none, :losing?
  end

  # ...and a reading that WAS taken and found nothing says that instead.
  def test_a_clean_reading_is_measured_and_not_losing
    same = marked(40)
    reading = read([same, same.dup], [same.dup, same.dup])

    assert_predicate reading, :measured?
    refute_predicate reading, :losing?
  end
end

# Which screens the question applies to. A game has one screen or the other, so
# exactly one of Flicker/Tearing can be asked of it.
class TestFlickerMeasurable < Minitest::Test
  include RubyGBA::IR::Build

  def program_on(**opts)
    program(screen(:bitmap, **opts), clear_screen(:blue), halt)
  end

  def test_a_tear_free_screen_can_lose_drawing
    assert RubyGBA::Flicker.measurable?(program_on(buffered: true))
  end

  def test_a_plain_bitmap_screen_cannot
    refute RubyGBA::Flicker.measurable?(program_on)
  end

  # The two are never both asked of one game: a screen keeps one picture or two,
  # and each question is about exactly one of those cases.
  def test_the_two_questions_are_never_both_asked
    [program_on, program_on(buffered: true),
     program(screen(:tiled), halt), program(screen(:rotozoom), halt)].each do |prog|
      asked = [RubyGBA::Flicker.measurable?(prog), RubyGBA::Tearing.measurable?(prog)]
      assert_operator asked.count(true), :<=, 1,
                      "at most one question should apply, got #{asked.inspect}"
    end
  end

  # On a screen with pixels of its own, exactly one of them IS asked — so a bitmap
  # game is never left with no question answered about its picture. A tiled screen
  # has no framebuffer, so neither applies and both say "not measured".
  def test_a_bitmap_screen_always_gets_one_of_the_two
    [program_on, program_on(buffered: true)].each do |prog|
      asked = [RubyGBA::Flicker.measurable?(prog), RubyGBA::Tearing.measurable?(prog)]
      assert_equal 1, asked.count(true), "a bitmap screen should get one question, got #{asked.inspect}"
    end
  end
end

# The same rule on the reference interpreter, which models the two pictures too.
#
# It needs no stepping API: the interpreter is deterministic, so running the same
# program for N frames and for N+2 gives exactly the two snapshots the rule wants —
# and two flips apart the pictures are back in the same roles, so they are labelled
# the same way in both.
class TestFlickerOnTheInterpreter < Minitest::Test
  MARKS = 24
  STEP = 8

  # +kept+ draws every mark on two frames running, so both pictures get it.
  def trail(kept:)
    b = Builder.new
    marks = MARKS
    step = STEP
    b.instance_eval do
      screen :bitmap, tear_free: true
      clear_screen :black
      n = var :n, 0
      game_loop do
        n.add 1
        (n <= marks).then { draw_rect_at n * step, 40, 6, 6, :red }
        ((n >= 2) & (n <= marks + 1)).then { draw_rect_at (n - 1) * step, 40, 6, 6, :red } if kept
      end
    end
    b.emit_pending_functions
    b.program
  end

  def reading_for(program, at: 30)
    before = Reference.new.run(program, frames: at).screen.pages
    after = Reference.new.run(program, frames: at + 2).screen.pages
    RubyGBA::Flicker.read(before, after)
  end

  def test_a_trail_drawn_once_is_caught
    reading = reading_for(trail(kept: false))

    assert_predicate reading, :losing?
    # EVERY mark flickers, not half of them. Half land in each picture, so each one is
    # present in one picture and missing from the other — which is a disagreement at all
    # of them. The player sees the whole trail blinking, not half a trail.
    assert_equal MARKS * 36, reading.pixels
  end

  def test_a_trail_drawn_into_both_pictures_is_not_caught
    refute_predicate reading_for(trail(kept: true)), :losing?
  end
end
