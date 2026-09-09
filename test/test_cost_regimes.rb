# frozen_string_literal: true

require "test_helper"
require "stringio"
require_relative "../tools/cost_regimes"

# The blind-spot report (tools/cost_regimes.rb): which parts of the cost model has anything
# ever run through, and which has nothing.
#
# The measuring half needs every example built and priced once per weight, which is minutes —
# so what is asserted here is the READING: that a regime nothing reaches is called out, that
# one everything reaches for nothing is not mistaken for it, and that a regime propped up by a
# single program is named. Those are the three answers the report exists to give, and each is
# a distinction it would be easy to get subtly wrong.
class TestCostRegimes < Minitest::Test
  def regime(weight, value: 0.01, times: 100.0, programs: 5, note: "a note")
    CostRegimes::Regime.new(weight: weight, value: value, times: times, programs: programs,
                            note: note)
  end

  def rendered(regimes)
    io = StringIO.new
    CostRegimes.report(regimes, out: io)
    io.string
  end

  # THE POINT OF THE REPORT. A weight nothing exercises has never been wrong because nothing
  # has ever asked it, and the first game to reach one reads as a fresh mystery.
  def test_a_regime_nothing_reaches_is_named
    out = rendered([regime(:busy), regime(:untouched, times: 0.0, programs: 0,
                                          note: "one line's interrupt")])

    assert_match(/NEVER EXERCISED/, out)
    assert_match(/untouched\s+one line's interrupt/, out, "and says what it is, not just its name")
    refute_match(/busy.*one line's interrupt/, out)
  end

  # THE DISTINCTION THE FIRST VERSION GOT WRONG. Taking a weight away cannot tell "nothing
  # asks for this" from "everything asks for it and it is measured at nothing" — both leave
  # the frames unchanged. var_operand is the second, and reading it as a blind spot would send
  # somebody looking for a program that exercises what every program already does.
  def test_a_regime_that_is_exercised_and_free_is_not_a_blind_spot
    out = rendered([regime(:free_one, value: 0.0, times: 5000.0, programs: 20)])

    refute_match(/NEVER EXERCISED/, out)
    assert_match(/MEASURED AT NOTHING/, out)
    assert_match(/free_one/, out)
  end

  # A regime the whole corpus rests on, with one program holding it up. If that weight is
  # wrong, one reading is wrong and nothing else in the corpus disagrees with it.
  def test_a_regime_with_a_single_witness_is_named_when_it_carries_real_time
    out = rendered([regime(:crowd, times: 1000.0, programs: 20),
                    regime(:lonely, times: 900.0, programs: 1)])

    assert_match(/ONE WITNESS ONLY/, out)
    assert_match(/^ {2}lonely\s+\d+\.\d%/, out)
  end

  # ...and one that carries nothing is not, or the section is a wall of rounding errors and
  # the ones that matter are lost in it.
  def test_a_single_witness_that_carries_nothing_is_summarised_not_listed
    out = rendered([regime(:crowd, times: 100_000.0, programs: 20),
                    regime(:slight, times: 1.0, programs: 1)])

    assert_match(/and 1 more carrying almost none of the corpus/, out)
    assert_match(/slight/, out)
    refute_match(/^ {2}slight\s+\d+\.\d%/, out, "named in the summary line, not given a row")
  end

  # The headline number: how much of the model the corpus reaches is the one thing worth
  # remembering from a run.
  def test_it_says_how_much_of_the_model_the_corpus_covers
    out = rendered([regime(:a), regime(:b), regime(:c, times: 0.0, programs: 0)])

    assert_match(/2 of 3 regimes are exercised/, out)
  end

  # A corpus that reaches everything says so, rather than printing an empty heading.
  def test_a_corpus_with_no_blind_spots_says_so
    assert_match(/no blind spots/, rendered([regime(:a), regime(:b)]))
  end

  # The weights that are not a count of anything — a factor the model divides by — still get
  # a row, because what changes when they are wrong is worth knowing; they just do not claim
  # to be a number of times a frame.
  def test_a_weight_that_is_not_a_count_does_not_report_one
    refute CostRegimes.counts?(:fast_code_speedup)
    assert CostRegimes.counts?(:op_step)
  end
end
