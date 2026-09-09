# frozen_string_literal: true

require_relative "helper"

# SAYING HOW OFTEN A GUARDED BODY RUNS.
#
# The estimate can see through only three kinds of test on its own: a `pressed` edge (a
# transition, so no frame in particular), a `chance(n)` (it says its own odds), and a walk over
# a pool's slots (the live ones are counted). EVERY OTHER TEST is a value the game works out,
# which nothing at build time can see through — so the body behind it is counted on every frame.
#
# That is the safe reading and it is often badly wrong. A death animation, a screen that
# repaints only when a number changed, a routine that answers a rare event: each reads as
# ordinary every-frame work. It is not a small error either — in a real game the two worst
# offenders came to about a quarter of the frame the report charged for.
#
# So the author can say, with the same word the other estimates use, and — like those — it
# changes NOTHING about how the game runs.
class TestHowOften < Minitest::Test
  include CostArith

  Cost = RubyGBA::IR::CostModel

  BUSY = 200 # far above everything else in the program, so the body is what the frame reads as

  def guarded(estimate)
    RubyGBA.game("OFTEN", code: "ZOFT", maker: "01") do
      screen :bitmap
      total = var :total, 0
      state = var :state, 0
      game_loop do
        (state == 1).then(estimate: estimate) { BUSY.times { total.add 1 } }
      end
    end.program
  end

  # What the PROGRAM costs a frame, with the frame's own boundary taken off: every reading
  # here carries it, and it would flatten every share this file is about.
  def steady(estimate) = Cost.new.steady_cost(guarded(estimate)) - frame_boundary
  def worst(estimate) = Cost.new.frame_cost(guarded(estimate)) - frame_boundary

  # UNSAID, IT IS COUNTED EVERY FRAME. Pinned so the safe default cannot drift: a game that
  # says nothing must never be told it is cheaper than it is.
  def test_a_test_the_game_works_out_is_counted_on_every_frame
    assert_in_delta steady(nil), worst(nil), 0.01,
                    "nothing said, so a usual frame is charged what the worst one is"
  end

  # ...and said, it is counted that often. `usually: 0` is the common one — a body that runs on
  # no ordinary frame at all.
  def test_a_body_that_runs_on_no_ordinary_frame_costs_almost_nothing
    assert_operator steady({ usually: 0 }), :<, steady(nil) / 50,
                    "what is left is the test itself, not the body behind it"
  end

  # The share scales the BODY. Making the test is not scaled by anything — it happens every
  # frame whatever the answer is — so it is held out on both sides rather than divided too.
  def test_a_share_is_counted_as_that_share
    just_the_test = steady({ usually: 0 })
    body = steady(nil) - just_the_test

    assert_in_delta body / 60, steady({ usually: 1, in: 60 }) - just_the_test, body / 100
    assert_in_delta body / 10, steady({ usually: 1, in: 10 }) - just_the_test, body / 100
    assert_in_delta steady(nil), steady({ usually: 1 }), 0.01, "once in one frame is every frame"
  end

  # THE WORST FRAME DOES NOT MOVE, and this is what keeps the hint honest. A frame where the
  # body DOES run really does pay for it, so the worst case counts it whole however rare it is
  # — the same bargain a list's usual length strikes with its capacity.
  def test_the_worst_frame_still_pays_for_it_whatever_was_said
    [nil, { usually: 0 }, { usually: 1, in: 60 }].each do |estimate|
      assert_in_delta worst(nil), worst(estimate), 0.01,
                      "the worst frame is one where it runs, whatever #{estimate.inspect} said"
    end
  end

  # WHAT THE HINT MUST NOT CHANGE is what the game DOES. It may change what the build keeps
  # in quick memory — that is the point of it, since a rare body should not hold that memory
  # against one that runs every frame — so the emitted bytes are allowed to differ. What runs
  # is not: the same statements, the same order, the same answers.
  #
  # Run to the same number of frames with the test made TRUE, so the guarded body is actually
  # exercised rather than skipped on both sides.
  def counting(estimate)
    RubyGBA.game("SAME", code: "ZSAM", maker: "01") do
      screen :bitmap
      total = var :total, 0
      state = var :state, 1
      game_loop do
        (state == 1).then(estimate: estimate) { 5.times { total.add 3 } }
      end
    end.program
  end

  def test_the_hint_changes_nothing_the_game_does
    plain = Reference.new.run(counting(nil), frames: 20)
    hinted = Reference.new.run(counting({ usually: 0 }), frames: 20)

    assert_operator plain[:total], :>, 0, "the guarded body has to actually run for this to mean anything"
    assert_equal plain[:total], hinted[:total],
                 "saying how often a body runs must not change what it computes"
  end

  # --- what it refuses -------------------------------------------------------------

  def refusal(estimate)
    assert_raises(ArgumentError) { guarded(estimate) }.message
  end

  def test_it_says_what_the_hint_looks_like
    assert_match(/in braces/, refusal(5))
    assert_match(/needs `usually:`/, refusal({ in: 60 }))
  end

  def test_a_misspelt_key_names_the_ones_it_knows
    message = refusal({ usualy: 0 })

    assert_match(/usualy/, message)
    assert_match(/usually, in/, message)
  end

  def test_a_body_cannot_run_more_often_than_every_frame
    assert_match(/more often than every frame/, refusal({ usually: 2, in: 1 }))
  end

  def test_the_counts_must_be_whole_and_not_negative
    assert_match(/0 or more/, refusal({ usually: -1 }))
    assert_match(/1 or more/, refusal({ usually: 1, in: 0 }))
  end
end
