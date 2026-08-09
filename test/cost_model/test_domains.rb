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

  # THE CASE THIS EXISTS FOR. overlap_pixel is measured on walks of 64 to 256 cells, and the
  # rate leaves out whatever such a walk pays once. Asked about a walk an order of magnitude
  # smaller, it is quietly light — so the estimate says so instead of answering confidently.
  def test_a_walk_far_below_where_its_weight_was_measured_is_reported
    notes = Cost.new.domain_notes(tiny_collisions)

    assert_equal 1, notes.length
    note = notes.first
    assert_equal :overlap_pixel, note[:weight]
    assert_equal :overlap_pixels, note[:varies]
    assert_operator note[:count], :<, 64 * Cost::Domains::FAR_BELOW
  end

  # ...and the report says it out loud, at the top, in the same voice as an unpriced op.
  def test_the_report_says_it_at_the_top
    out = reported(tiny_collisions)

    assert_match(/overlap_pixel was measured over 64\.\.256 overlap_pixels/, out.lines.first)
    assert_match(/reads LOW/, out.lines.first)
  end

  # Two sprites the size of a full stop, tested against each other. Small enough that the walk
  # is far under where its weight was measured, and dear enough per cell that being wrong about
  # six of them is still worth a scanline — both are needed before it is worth saying.
  def tiny_collisions
    program do
      screen :bitmap
      image(:dot, "#" => :red) { "##\n##\n##" } # 2 x 3, so a walk covers six cells
      a = sprite :dot, at: [10, 10]
      b = sprite :dot, at: [12, 10]
      hits = var :hits, 0
      game_loop { a.overlaps?(b).then { hits.add 1 } }
    end
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
