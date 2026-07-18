# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# The guardrail mechanism on its own: a registry of checks and a pass that runs
# them over an IR tree, reporting findings and optionally applying safe fixes.
# Tested here with a stub check so the plumbing is exercised independently of any
# real footgun (those get their own tests).
class TestIRGuardrails < Minitest::Test
  include RubyGBA::IR::Build

  Guardrails = RubyGBA::IR::Guardrails

  # A check that simply returns whatever findings it was handed.
  class StubCheck
    def initialize(findings)
      @findings = findings
    end

    def detect(_program)
      @findings
    end
  end

  def error(message, fix: nil)
    Guardrails::Finding.new(check: :stub, severity: :error, message: message, fix: fix)
  end

  def validate(checks, program, **opts)
    Guardrails::Validator.new(checks: checks).run(program, **opts)
  end

  def test_detected_problem_without_a_fix_is_an_error
    report = validate([StubCheck.new([error("boom")])], program(set(:x, 1)))
    refute report.ok?
    assert_equal ["boom"], report.errors.map(&:message)
  end

  def test_raise_on_error_raises_with_the_message
    report = validate([StubCheck.new([error("boom")])], program)
    err = assert_raises(Guardrails::ValidationError) { report.raise_on_error! }
    assert_match(/boom/, err.message)
  end

  def test_a_safe_fix_is_applied_and_downgraded_to_a_warning
    replacement = program(set(:fixed, 1))
    fix = Guardrails::Fix.new(message: "fixed it", apply: ->(_prog) { replacement })
    report = validate([StubCheck.new([error("boom", fix: fix)])], program(set(:x, 1)))

    assert report.ok?, "a fixed problem should not leave an error"
    assert_equal ["fixed it"], report.warnings.map(&:message)
    assert_same replacement, report.program
    report.raise_on_error! # must not raise
  end

  def test_autofix_off_keeps_the_error_and_leaves_the_program_untouched
    original = program(set(:x, 1))
    fix = Guardrails::Fix.new(message: "fixed it", apply: ->(_prog) { program(set(:fixed, 1)) })
    report = validate([StubCheck.new([error("boom", fix: fix)])], original, autofix: false)

    refute report.ok?
    assert_same original, report.program
  end

  def test_checks_run_in_order_and_findings_accumulate
    a = StubCheck.new([error("a")])
    b = StubCheck.new([error("b")])
    report = validate([a, b], program)
    assert_equal %w[a b], report.errors.map(&:message)
  end

  def test_a_clean_program_reports_nothing
    report = validate([StubCheck.new([])], program(set(:x, 1)))
    assert report.ok?
    assert_empty report.findings
  end
end
