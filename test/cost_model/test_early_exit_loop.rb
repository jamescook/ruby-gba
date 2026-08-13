# frozen_string_literal: true

require_relative "helper"

# A LOOP THAT STOPS EARLY, and what a frame should be told it costs.
#
# `repeat(n, stop_when: ...)` leaves as soon as the condition holds, so its count is a CEILING
# rather than a number of passes — and nothing in the program says where it really leaves. That
# is the same shape of unknown a list's length is, from the other side, and it is answered the
# same way: the author can say, and where they have not the estimate guesses and says so.
#
# It matters more here than for a list, because a ceiling is picked so it can never be reached
# AND this kind of loop usually sits inside another one, so the over-count multiplies.
class TestEarlyExitLoop < Minitest::Test
  include CostArith

  Cost = RubyGBA::IR::CostModel
  CEILING = 40

  # A loop that walks up to CEILING times looking for something, inside a loop of its own —
  # the shape a first-person view is made of.
  def searching_game(estimate: nil, stop: true)
    RubyGBA.game("SEEK", code: "ZSEK", maker: "01") do
      screen :bitmap
      found = var :found, 0
      total = var :total, 0
      game_loop do
        repeat(8) do
          found.set 0
          repeat(CEILING, stop_when: stop ? (found == 1) : nil, estimate: estimate) do |step|
            total.add step
            (total > 100).then { found.set 1 }
          end
        end
      end
    end.program
  end

  # What a frame USUALLY costs, against what the worst one could.
  def estimated(program) = Cost.new.steady_cost(program)
  def worst(program) = Cost.new.frame_cost(program)

  def report_of(program)
    io = StringIO.new
    Cost.new.render(program, out: io)
    io.string
  end

  # THE HEART OF IT: a loop that can leave early must not be counted as if it never does.
  def test_it_is_not_priced_at_its_ceiling
    stopping = estimated(searching_game)
    running = estimated(searching_game(stop: false))

    assert_operator stopping, :<, running,
                    "a loop that can stop early should cost less than one that cannot"
  end

  # ...and the author can say how soon, which is the only way anything can know.
  def test_saying_how_soon_it_stops_is_what_gets_counted
    few = estimated(searching_game(estimate: { usually: 2 }))
    many = estimated(searching_game(estimate: { usually: 20 }))

    assert_operator few, :<, many
    # Twenty passes against two is ten times the body, so the loop's share should move with it
    # rather than being pinned near the ceiling.
    assert_operator many / few, :>, 3.0, "the number given should really drive the estimate"
  end

  # Unsaid, it guesses — and a guess that is never admitted is worse than no guess at all.
  def test_the_report_says_whether_the_number_was_given_or_guessed
    guessed = report_of(searching_game)
    said = report_of(searching_game(estimate: { usually: 6 }))

    assert_match(/a loop that stops early counts the passes it usually makes/, guessed)
    assert_match(/a guess/, guessed)
    assert_match(/estimate: \{ usually: N \}/, guessed, "and how to give the real number")

    assert_match(/6 of #{CEILING}/, said)
    assert_match(/the number you gave/, said)
    refute_match(/a guess/, said)
  end

  # The ceiling has not gone away — a frame CAN reach it, and the worst case still says so.
  def test_the_worst_case_still_counts_every_pass
    program = searching_game(estimate: { usually: 2 })

    assert_operator worst(program), :>, estimated(program) * 3,
                    "the worst case should still be near the ceiling"
  end

  # A loop with no early exit already knows how many passes it makes, so a hint is either a
  # repetition or a contradiction. Saying so beats quietly ignoring it.
  def test_the_hint_is_refused_on_a_loop_that_cannot_stop_early
    err = assert_raises(ArgumentError) { searching_game(estimate: { usually: 3 }, stop: false) }

    assert_match(/stop_when/, err.message)
  end

  # A loop with no ceiling to compare against still takes a number.
  def test_a_count_the_game_works_out_can_still_be_told_how_soon_it_stops
    program = RubyGBA.game("SEEK2", code: "ZSK2", maker: "01") do
      screen :bitmap
      many = var :many, 30
      found = var :found, 0
      game_loop do
        repeat(many, stop_when: found == 1, estimate: { usually: 4 }) { found.set 1 }
      end
    end.program

    assert_match(/4 of \?/, report_of(program))
  end
end
