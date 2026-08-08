# frozen_string_literal: true

require "test_helper"

require_relative "../tools/calibration/reductions"
require_relative "../tools/calibration/domain"
require_relative "../tools/calibration/fake_measurer"
require_relative "../tools/calibration/calibrator"
require_relative "../tools/calibration/weights_fixture"

# The calibration tool itself (tools/calibration/), which measures every weight the cost model
# charges. It used to be one flat script welded to the emulator, so none of it could be tested;
# now the emulator sits behind one seam and everything else — the recipes, the arithmetic, the
# file it writes — runs against canned readings.
#
# NOTHING HERE REQUIRES GEMBA. That is the point of the seam and it is worth keeping: these are
# the tests that say the tool's own logic is right, and they must not depend on the thing the
# tool measures. (What the emulator actually reads is checked by test_cost_calibration.rb,
# which is a different question.)
class TestCostCalibrationTool < Minitest::Test
  Calibration = RubyGBA::Calibration
  Reductions = Calibration::Reductions
  Domain = Calibration::Domain

  # --- the arithmetic, on known numbers ---

  # The workhorse: two ROMs that differ only in how many of the thing they do, over the
  # difference. Everything they share cancels, which is what leaves the thing's own cost.
  def test_a_marginal_rate_is_the_difference_over_the_spread
    assert_in_delta 0.5, Reductions.marginal(60.0, 10.0, over: 100), 1e-9
  end

  # Dividing by no spread is not a very large rate, it is a bug in the recipe — two ROMs that
  # do the same amount cannot say what one more costs.
  def test_a_marginal_rate_with_no_spread_is_an_error
    assert_raises(ArgumentError) { Reductions.marginal(60.0, 10.0, over: 0) }
  end

  # A compound op's fixed part: its whole cost, minus the parts already priced.
  def test_a_residual_takes_the_priced_parts_out_of_a_whole
    assert_in_delta 2.0, Reductions.residual(10.0, 5.0, 3.0), 1e-9
  end

  # Negative is allowed and is a real signal — it means the parts over-account for the whole, so
  # one of them is measuring something this total does not contain.
  def test_a_residual_may_come_out_negative
    assert_operator Reductions.residual(1.0, 5.0), :<, 0
  end

  # base + slope * n through two points, for a cost with a floor (the software mixer pays to run
  # at all, then a rate per sounding voice).
  def test_a_fit_finds_the_slope_and_the_floor
    slope, base = Reductions.fit(1, 13.0, 8, 34.0)
    assert_in_delta 3.0, slope, 1e-9
    assert_in_delta 10.0, base, 1e-9, "with no voices at all it still costs the floor"
  end

  def test_a_fit_needs_two_different_counts
    assert_raises(ArgumentError) { Reductions.fit(4, 1.0, 4, 2.0) }
  end

  def test_a_ratio_is_how_many_times_faster
    assert_in_delta 2.5, Reductions.ratio(50.0, 20.0), 1e-9
    assert_raises(ArgumentError) { Reductions.ratio(50.0, 0) }
  end

  # --- a weight's domain ---

  def test_a_domain_knows_what_it_covers
    d = Domain.new(varies: :passes, from: 300, to: 900)
    assert d.covers?(300)
    assert d.covers?(900)
    refute d.covers?(4)
    refute d.covers?(2000)
  end

  # Below the floor is the direction that hurts, and the domain says so separately: a marginal
  # rate excludes whatever the thing pays once, and the smaller the count the bigger a share of
  # the cost that is. Above the range, extrapolating a linear rate is usually harmless.
  def test_only_below_the_floor_is_flagged_as_the_dangerous_side
    d = Domain.new(varies: :passes, from: 300, to: 900)
    assert d.under?(4)
    refute d.under?(2000)
  end

  # A weight with no countable regime covers everything — an add costs what an add costs, and no
  # number in a program changes it, so there is nothing to warn about.
  def test_a_weight_with_no_countable_regime_covers_everything
    d = Domain.new(note: "an add")
    assert d.covers?(1)
    assert d.covers?(1_000_000)
    refute d.under?(0)
  end

  # --- the file the tool writes ---

  # The renderer reproduces the COMMITTED fixture byte for byte from the committed weights. This
  # is what says the refactor changed nothing about the output: same numbers in, same file out.
  def test_it_renders_the_committed_fixture_exactly
    rendered = Calibration::WeightsFixture.new(weights: RubyGBA::IR::CostModel::MEASURED_WEIGHTS).render
    assert_equal File.read(fixture_path), rendered
  end

  def fixture_path
    File.expand_path("../lib/ruby_gba/ir/measured_weights.rb", __dir__)
  end

  # Given domains, it writes them too — and the rendered source has to be valid Ruby that
  # actually defines them, not just text that looks right.
  def test_it_renders_the_domains_when_a_calibration_recorded_them
    source = Calibration::WeightsFixture.new(
      weights: { op_step: 0.5, loop_pass: 0.25 },
      domains: { op_step: Domain.new(note: "an add"),
                 loop_pass: Domain.new(varies: :passes, from: 300, to: 900) },
    ).render

    assert_match(/WEIGHT_DOMAINS = \{/, source)
    assert_match(/loop_pass: \{ varies: :passes, from: 300, to: 900 \}/, source)
    assert_match(/op_step: \{ note: "an add" \}/, source)
  end

  # ...and none at all when nothing recorded any, so a tool that does not measure domains still
  # writes the file it always wrote.
  def test_it_leaves_the_domains_out_when_there_are_none
    refute_match(/WEIGHT_DOMAINS/,
                 Calibration::WeightsFixture.new(weights: { op_step: 0.5 }).render)
  end

  # The rendered source is loaded and its constants read, which is the only assertion that
  # cannot be fooled by a plausible-looking string.
  def test_the_rendered_source_is_loadable_ruby
    source = Calibration::WeightsFixture.new(
      weights: { op_step: 0.5 },
      domains: { op_step: Domain.new(varies: :passes, from: 2, to: 9) },
    ).render
    mod = Module.new
    mod.module_eval(source.sub("module RubyGBA", "module Fixture"))

    assert_in_delta 0.5, mod::Fixture::IR::CostModel::MEASURED_WEIGHTS[:op_step], 1e-9
    assert_equal({ varies: :passes, from: 2, to: 9 },
                 mod::Fixture::IR::CostModel::WEIGHT_DOMAINS[:op_step])
  end

  # --- the recipes, against canned readings ---

  # Every reading answers the same number, so every marginal rate comes out at zero. Useless as
  # a value and exactly right as a wiring check: it runs all 48 recipes and says they produce
  # the weights the model expects, in the order the fixture wants them.
  def flat_calibration(default: 1.0, busy: {})
    fake = Calibration::FakeMeasurer.new(busy: busy, default: default)
    [Calibration::Calibrator.new(fake).run, fake]
  end

  def test_it_produces_exactly_the_weights_the_model_uses_in_the_committed_order
    calibration, = flat_calibration
    assert_equal RubyGBA::IR::CostModel::MEASURED_WEIGHTS.keys, calibration.weights.keys
  end

  # No weight may ship without a record of where it was measured. This is the guard that stops
  # the next weight being added as a bare number with no domain — the same job the conformance
  # fixture does for an unpriced IR kind.
  def test_every_weight_carries_a_domain
    calibration, = flat_calibration
    missing = calibration.weights.keys - calibration.domains.keys
    assert_empty missing, "these weights were measured with no record of where"
    assert(calibration.domains.each_value.all? { |d| d.note || d.varies },
           "a domain with neither a range nor a note says nothing")
  end

  # A real recipe, end to end, on numbers chosen so the answer is known. loop_pass differences a
  # 900-pass loop against a 300-pass one: 61 minus 1, over the 600 extra passes.
  def test_a_recipe_reduces_its_readings_the_way_it_says
    calibration, = flat_calibration(busy: { "lp900" => 61.0, "lp300" => 1.0 })
    assert_in_delta 0.1, calibration.weights[:loop_pass], 1e-9
  end

  # And the domain it records is the sweep it actually ran, not a number typed beside it.
  def test_the_domain_records_the_sweep_the_recipe_ran
    calibration, = flat_calibration
    domain = calibration.domains[:loop_pass]
    assert_equal :passes, domain.varies
    assert_equal 300, domain.from
    assert_equal 900, domain.to
  end

  # A reading nobody canned raises rather than answering zero. A test that quietly measured
  # nothing would pass while proving nothing.
  def test_an_unknown_reading_is_an_error_not_a_zero
    fake = Calibration::FakeMeasurer.new(busy: { "lp300" => 1.0 })
    assert_raises(KeyError) { Calibration::Calibrator.new(fake).run }
  end
end
