# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"

# The orphaned-Condition guardrail: catches the native-`if` slip. A comparison in
# this DSL is a Condition object, which Ruby treats as always-true — so `if x > 5`
# runs its body unconditionally with the comparison silently ignored, no error, a
# black-screen-class bug. Ruby gives no hook to intercept `if <truthy>`, so we
# detect the fingerprint instead: a Condition built but never used to branch
# (.then / .else) or folded into another (& / |). The builder tracks every
# Condition and reports the unused ones at build-finalize.
class TestIRGuardrailOrphanedCondition < Minitest::Test
  Builder = RubyGBA::Builder
  Guardrails = RubyGBA::IR::Guardrails

  # The Conditions a build block left unused (the builder's leftover "pending" set).
  def orphans_for(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.pending_conditions
  end

  # ---- which Conditions are orphaned --------------------------------------

  def test_a_comparison_never_used_to_branch_is_orphaned
    orphans = orphans_for do
      x = var :x, 5
      x > 3 # built, never `.then`-ed — the native-if slip
    end

    assert_equal 1, orphans.size
  end

  def test_a_comparison_used_with_then_is_not_orphaned
    orphans = orphans_for do
      x = var :x, 5
      (x > 3).then { set :y, 1 }
    end

    assert_empty orphans
  end

  def test_a_then_else_chain_is_not_orphaned
    orphans = orphans_for do
      x = var :x, 5
      (x > 3).then { set :y, 1 }.else { set :y, 0 }
    end

    assert_empty orphans
  end

  def test_composed_conditions_all_count_as_used_when_branched
    orphans = orphans_for do
      x = var :x, 5
      y = var :y, 2
      ((x > 3) & (y < 10)).then { set :z, 1 }
    end

    assert_empty orphans, "both operands are folded in by `&`, and the result is `.then`-ed"
  end

  def test_a_composed_condition_never_branched_is_orphaned_once
    orphans = orphans_for do
      x = var :x, 5
      y = var :y, 2
      (x > 3) & (y < 10) # the two operands are consumed by `&`; the result is not
    end

    assert_equal 1, orphans.size, "only the un-branched combined Condition is orphaned"
  end

  def test_a_bare_held_is_orphaned
    orphans = orphans_for { held(:a) } # held(:a) with no `.then` does nothing

    assert_equal 1, orphans.size
  end

  def test_held_used_with_then_is_not_orphaned
    orphans = orphans_for { held(:a).then { set :y, 1 } }

    assert_empty orphans
  end

  # ---- it points at the author's line -------------------------------------

  def test_the_orphan_records_where_the_author_built_it
    orphan = orphans_for do
      x = var :x, 5
      x > 3
    end.first

    assert_includes orphan.source, "test_ir_guardrail_orphaned_condition.rb",
                    "the source points at the author's file, not the library"
  end

  # ---- the explain half: it's an error, and it teaches --------------------

  def test_the_finding_is_an_error_that_names_the_source_and_the_fix
    orphan = orphans_for do
      x = var :x, 5
      x > 3
    end.first
    finding = Guardrails::Checks::OrphanedCondition.finding(orphan)

    assert finding.error?, "an unused Condition is a definite bug, not advisory"
    assert_equal :orphaned_condition, finding.check
    assert_match(/\.then/, finding.message, "the message names the fix")
    assert_match(/test_ir_guardrail_orphaned_condition\.rb:\d+/, finding.full_message,
                 "it sends the reader to the line that built the comparison")
    refute_includes finding.message, finding.source,
                    "the location is appended by full_message, not written into the message"
  end

  # ---- build-finalize surfaces it -----------------------------------------

  def test_build_halts_on_a_native_if_slip
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("GUARD", code: "BGRD", maker: "01", out: StringIO.new, err: err) do
        screen :bitmap
        x = var :x, 5
        if x > 3        # the footgun: a native `if` on a Condition
          set :y, 1
        end
        halt
      end
    end

    assert_match(/uses it to branch/, err.string)
    assert_match(/\.then/, err.string)
  end

  def test_build_is_quiet_when_you_branch_with_then
    err = StringIO.new
    RubyGBA.build("GUARD", code: "BGRD", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      x = var :x, 5
      (x > 3).then { set :y, 1 }
      halt
    end

    refute_match(/never used to branch/, err.string)
  end
end
