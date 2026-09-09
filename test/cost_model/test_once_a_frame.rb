# frozen_string_literal: true

require_relative "helper"

# WHAT A `once_a_frame` BODY COSTS A FRAME.
#
# Its call sits in a loop counted by how many frames the pass that just ended answered for, and
# that count is a variable — so by the general rule it is unbounded, has no provable size, and
# is charged nothing at all. That rule is right for a loop over something the program works out.
# It is wrong here, and wrong in the direction that matters: the estimate is what an author
# decides by, so a `shake_screen`, a fade, or a whole game's movement moved onto the clock read
# as FREE, and moving work into one made the frame look cheaper than leaving it in the loop.
#
# This count is not a guess at either end. A pass that keeps up is worth one frame, which is
# what every frame of a game that fits costs; and however late a pass runs it is held at a cap,
# which is the most it can ever cost.
class TestOnceAFrameCost < Minitest::Test
  include CostArith

  Cost = RubyGBA::IR::CostModel
  Frames = RubyGBA::IR::Frames
  BUSY = 20 # statements, enough that the difference is far above the noise of anything else

  # The same work, said the two ways round: in the game loop's own body, or on the clock.
  def game(on_the_clock:, busy: BUSY)
    RubyGBA.game("OAFC", code: "ZOAF", maker: "01") do
      screen :bitmap
      spin = var :spin, 0
      work = -> { busy.times { spin.add 1 } }
      once_a_frame(&work) if on_the_clock
      game_loop { work.call unless on_the_clock }
    end.program
  end

  # What the WORK costs, with the wrapper around it taken off both sides. A body on the clock
  # is reached through a loop and a call and that is real, so the two totals do not match — but
  # what each added statement costs must, or the body is not being counted.
  def per_statement(on_the_clock:)
    (steady(game(on_the_clock: on_the_clock)) - steady(game(on_the_clock: on_the_clock, busy: 0))) / BUSY
  end

  # What the PROGRAM costs a frame, with the frame's own boundary taken off. A late pass
  # replays the body on the clock; it does not wait for the screen again, so the boundary is
  # paid once however late the pass was and has no business in the catching-up arithmetic.
  def steady(program) = Cost.new.steady_cost(program) - frame_boundary
  def worst(program) = Cost.new.frame_cost(program) - frame_boundary

  def report_of(program)
    io = StringIO.new
    Cost.new.render(program, out: io)
    io.string
  end

  # THE HEART OF IT. Twenty statements cost twenty statements wherever they are written, and a
  # game that keeps up runs them once either way. Priced as unbounded, the one on the clock came
  # out at nothing.
  def test_a_body_on_the_clock_costs_a_frame_what_the_same_body_in_the_loop_costs
    assert_operator per_statement(on_the_clock: true), :>, 0,
                    "priced as unbounded, a body on the clock came out at nothing at all"
    assert_in_delta per_statement(on_the_clock: false), per_statement(on_the_clock: true), 0.001,
                    "the same work, and a frame that keeps up runs it once whichever way it is written"
  end

  # The wrapper it is reached through — a loop counted by the frames, and a call — is real work
  # of its own, so a body on the clock does cost a little more in total than the same lines
  # written in the loop. Small against the body, and it is a cost rather than a discount.
  def test_reaching_it_costs_a_little_and_that_is_all_the_difference_there_is
    extra = steady(game(on_the_clock: true)) - steady(game(on_the_clock: false))

    assert_operator extra, :>, 0
    assert_operator extra, :<, steady(game(on_the_clock: false)) / 2
  end

  # ...and the worst a frame can be is a pass so late it replays the body up to the cap, which is
  # the runaway an author most wants to see: a heavy frame makes the next one later, and a later
  # one runs the world more times. That is a real number, not a guess.
  def test_the_heaviest_frame_counts_the_catching_up_a_late_pass_does
    on_the_clock = game(on_the_clock: true)
    caught_up = worst(on_the_clock) - worst(game(on_the_clock: false))

    assert_operator caught_up, :>, 0, "a late pass runs the body again, and that is a real cost"
    assert_in_delta (Frames::MOST - 1) * steady(on_the_clock), caught_up, 0.5,
                    "held at the cap: the most it can ever be asked to catch up"
  end

  # The report says which of the two it counted, because "x? (unbounded)" is the note that used
  # to appear here and it means something quite different — it is the model saying it cannot
  # price this at all, and it drops the "run it to be sure" warning on the whole report.
  def test_the_report_names_the_count_rather_than_calling_it_unbounded
    report = report_of(game(on_the_clock: true))

    refute_includes report, "unbounded", "this one has a bound at both ends"
    assert_includes report, "x<=#{Frames::MOST}"
  end
end
