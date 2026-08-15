# frozen_string_literal: true

require_relative "helper"

# A LOOP COUNTED BY SOMETHING THE GAME WORKS OUT, and why it is the one shape the estimate can
# get catastrophically wrong.
#
# `repeat(8)` says how many passes it makes. `repeat(48, stop_when: ...)` says the most it can
# make, and the author fills in the rest. `repeat(n)` where n is a variable says NEITHER — there
# is no number anywhere in the program — so unsaid it is charged nothing at all.
#
# That is not a cautious guess, it is a hole, and a reader of the report cannot tell it from
# "cheap". It found a real game: the loop that draws everything standing in a room is this shape,
# and read as free it hid the largest cost in the frame from the one report meant to find it.
class TestWorkedOutLoop < Minitest::Test
  include CostArith

  Cost = RubyGBA::IR::CostModel

  # A loop over a count the game works out — here a number that could be anything by the time
  # the loop is reached, which is exactly what the estimate cannot see through.
  def counted_game(estimate: nil)
    RubyGBA.game("WORK", code: "ZWRK", maker: "01") do
      screen :bitmap
      many = var :many, 0
      total = var :total, 0
      game_loop do
        many.set(many + 1)
        many.clamp 0, 30
        repeat(many, estimate: estimate) { |step| total.add step }
      end
    end.program
  end

  def estimated(program) = Cost.new.steady_cost(program)
  def worst(program) = Cost.new.frame_cost(program)

  def report_of(program)
    io = StringIO.new
    Cost.new.render(program, out: io)
    io.string
  end

  # THE HOLE ITSELF, pinned so that closing it stays closed.
  def test_unsaid_it_is_charged_nothing_and_the_report_says_so
    bare = counted_game

    assert_in_delta 0.0, body_cost(bare), 0.01, "nothing in the program says how many passes"
    assert_match(/unbounded/, report_of(bare), "and the report has to admit it rather than imply cheap")
  end

  # ...AND SAID, IT COUNTS. This is the whole point: an author who knows can say, and then the
  # frame reads what it really costs.
  def test_saying_how_many_passes_it_usually_makes_prices_it
    said = counted_game(estimate: { usually: 10 })

    assert_operator body_cost(said), :>, 0, "ten passes of a body is not free"
    assert_in_delta body_cost(counted_game(estimate: { usually: 20 })), body_cost(said) * 2,
                    body_cost(said) * 0.3, "and twice the passes is about twice the cost"
  end

  # THE WORST CASE IS A DIFFERENT NUMBER and wants saying separately, because there is nothing in
  # the program to fall back on — a loop with a written count or an early exit has its ceiling
  # right there, and this one does not.
  def test_the_most_it_can_make_prices_the_worst_case
    said = counted_game(estimate: { usually: 4, most: 30 })

    assert_operator worst(said), :>, estimated(said) * 3,
                    "the worst frame runs thirty passes where a usual one runs four"
  end

  # Without `most:` the worst case has nothing better to go on than the usual figure, and the
  # report says which it used rather than quietly presenting a guess as a ceiling.
  def test_without_a_ceiling_the_report_says_the_most_is_not_known
    assert_match(/the most is not said/, report_of(counted_game(estimate: { usually: 4 })))
  end

  # --- what the hint may be said about --------------------------------------------

  # A loop counted by a NUMBER already knows both halves, so a hint there is either a repetition
  # or a contradiction — and a friendly error is better than quietly believing the wrong one.
  def test_a_loop_counted_by_a_number_refuses_the_hint
    error = assert_raises(ArgumentError) do
      RubyGBA.game("NUM", code: "ZNUM", maker: "01") do
        screen :bitmap
        total = var :total, 0
        game_loop { repeat(8, estimate: { usually: 3 }) { total.add 1 } }
      end.program
    end

    assert_match(/cannot count for itself/, error.message)
    assert_match(/stop_when/, error.message, "and says what would make it answerable")
  end

  # ...and `most:` in particular is only ever an answer where nothing else bounds the loop.
  def test_the_most_is_refused_where_the_count_already_says_it
    error = assert_raises(ArgumentError) do
      RubyGBA.game("MOST", code: "ZMST", maker: "01") do
        screen :bitmap
        found = var :found, 0
        game_loop do
          repeat(40, stop_when: found == 1, estimate: { usually: 3, most: 12 }) { found.set 1 }
        end
      end.program
    end

    assert_match(/already says that/, error.message)
  end

  private

  # What the loop's body costs a frame, with the loop's own overhead taken out by holding it
  # against the same game with no loop to run.
  def body_cost(program)
    estimated(program) - estimated(empty_game)
  end

  def empty_game
    @empty_game ||= RubyGBA.game("NONE", code: "ZNON", maker: "01") do
      screen :bitmap
      many = var :many, 0
      game_loop do
        many.set(many + 1)
        many.clamp 0, 30
      end
    end.program
  end
end
