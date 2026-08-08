# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# Where each weight can be trusted (lib/ruby_gba/ir/cost_model/domains.rb).
#
# Nearly every weight is a marginal rate — two ROMs differenced over how many of the thing they
# do — which cancels whatever the thing pays only ONCE. So a weight describes the range it was
# measured over, and outside that range it can be quietly wrong. The model already made a
# missing OP loud; these are the tests for making an out-of-range WEIGHT loud too.
class TestCostDomains < CostModelTest
  # --- every weight says where it came from ---

  # The guard that stops the next weight shipping as a bare number. It is the same job the
  # conformance fixture does for an unpriced IR kind: you cannot add one silently.
  #
  # The note is what makes measured_weights.rb readable as a SET — the one place a person can
  # see every weight, what each stands for and where it can be trusted, without grepping the
  # measurement script. There is deliberately no second document saying the same thing: a
  # generated copy of a generated file is one more thing to keep in step for no new fact.
  def test_every_weight_records_where_it_was_measured
    weights = Cost::MEASURED_WEIGHTS.keys
    domains = Cost::WEIGHT_DOMAINS
    assert_equal weights, domains.keys, "every weight needs a domain, in the same order"
    weights.each do |name|
      refute_empty domains[name], "#{name} has no record of where it was measured"
      assert domains[name][:note], "#{name} needs a note saying what it is, in plain words"
    end
  end

  # A weight with a countable regime has to say what it varied AND over what, or the range is
  # not checkable and the entry is decoration.
  def test_a_countable_regime_carries_a_range
    Cost::WEIGHT_DOMAINS.each do |name, domain|
      next unless domain[:varies]

      assert domain[:from], "#{name} names a quantity but no floor"
      assert domain[:to], "#{name} names a quantity but no ceiling"
      assert_operator domain[:to], :>=, domain[:from], "#{name}'s range runs backwards"
    end
  end

  # --- the check at use ---

  # A loop of +passes+ passes, run +outer+ times a frame.
  def nested_loops(passes:, outer:)
    program do
      screen :bitmap
      clear_screen :black
      n = var :n, 0
      game_loop { repeat(outer) { repeat(passes) { |i| n.add i } } }
    end
  end

  # THE CASE THIS EXISTS FOR. loop_pass was measured on loops of 300..900 passes; a four-pass
  # loop pays its setup over four passes and reads 0.87x of what the emulator measures. The
  # estimate now says so instead of answering confidently.
  def test_a_far_too_short_loop_is_reported
    notes = Cost.new.domain_notes(nested_loops(passes: 4, outer: 60))
    assert_equal 1, notes.length
    note = notes.first
    assert_equal :loop_pass, note[:weight]
    assert_equal :passes, note[:varies]
    assert_equal 4, note[:count]
    assert_operator note[:cost], :>, 10, "it is a real part of the frame, which is why it is said"
  end

  # ...and the report says it out loud, at the top, in the same voice as an unpriced op.
  def test_the_report_says_it_at_the_top
    out = reported(nested_loops(passes: 4, outer: 60))
    assert_match(/loop_pass was measured over 300\.\.900 passes/, out.lines.first)
    assert_match(/reads LOW/, out.lines.first)
  end

  # A loop only a little below the range is NOT reported. The excluded fixed cost is amortised
  # over the passes, so the error scales as 1/n: at 40 passes the same program measures 0.95x,
  # which is inside the model's usual band and not worth a word. Getting this wrong in the other
  # direction would fire on almost every game and teach people to ignore the line.
  def test_a_loop_just_below_the_range_is_left_alone
    assert_empty Cost.new.domain_notes(nested_loops(passes: 40, outer: 6))
  end

  # Nor is a short loop that costs the frame nothing. Being a sixth wrong about a quarter of a
  # scanline changes no decision.
  def test_an_immaterial_short_loop_is_left_alone
    assert_empty Cost.new.domain_notes(nested_loops(passes: 4, outer: 1))
  end

  # Nesting is followed and multiplied: a four-pass loop inside a sixty-pass one really makes 240
  # passes a frame, and that is what makes it material. Counting it as four would hide it.
  def test_nesting_is_multiplied_when_working_out_what_it_costs
    note = Cost.new.domain_notes(nested_loops(passes: 4, outer: 60)).first
    assert_in_delta 60 * 4 * Cost::DEFAULT_WEIGHTS[:loop_pass], note[:cost], 0.001
  end

  # A program well inside every range says nothing at all — which is the common case and the
  # thing that keeps the banner meaningful.
  def test_an_ordinary_program_is_silent
    plain = program do
      screen :bitmap
      clear_screen :black
      n = var :n, 0
      game_loop { n.add 1; fill_rect 0, 0, 40, 8, :green }
    end
    assert_empty Cost.new.domain_notes(plain)
    refute_match(/reads LOW/, reported(plain))
  end

  # A timer far below the rate its weight was measured at, but only 3% off measured, is not
  # reported either — the same 1/n reasoning, on a different weight.
  def test_a_slower_timer_than_the_measurement_is_left_alone
    timed = program do
      screen :bitmap
      n = var :n, 0
      timer(:beat, per_second: 3000).on_tick { n.add 1 }
      game_loop { }
    end
    assert_empty Cost.new.domain_notes(timed)
  end

  # An unrecorded weight cannot be checked and must not raise trying.
  def test_a_weight_with_no_recorded_domain_is_simply_not_checked
    assert_empty Cost.new.weight_domain(:not_a_weight)
  end

end
