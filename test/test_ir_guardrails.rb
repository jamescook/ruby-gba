# frozen_string_literal: true

require "test_helper"

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

  def error(message, fix: nil, node: :program)
    Guardrails::Finding.new(check: :stub, severity: :error, message: message, node: node, fix: fix)
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

  # ---- a finding has to say where to look ---------------------------------

  def test_a_finding_cannot_be_built_without_naming_what_it_blames
    err = assert_raises(ArgumentError) do
      Guardrails::Finding.new(check: :stub, severity: :error, message: "boom")
    end

    assert_match(/node/, err.message)
  end

  def test_a_finding_will_not_take_something_that_has_no_source
    assert_raises(ArgumentError) do
      Guardrails::Finding.new(check: :stub, severity: :error, message: "boom", node: "game.rb:42")
    end
  end

  def test_a_finding_sends_the_reader_to_the_line_of_the_node_it_blames
    node = set(:x, 1)
    node.source = "game.rb:42"

    finding = error("boom", node: node)

    assert_equal "game.rb:42", finding.source
    assert_equal "boom (at game.rb:42)", finding.full_message
    refute_includes finding.message, "game.rb:42", "the raw message stays location-free"
  end

  def test_a_whole_program_finding_says_so_and_carries_no_line
    finding = error("boom", node: :program)

    assert_nil finding.source
    assert_equal "boom", finding.full_message
  end

  def test_an_auto_fixed_finding_still_blames_the_same_node
    node = set(:x, 1)
    node.source = "game.rb:7"
    fix = Guardrails::Fix.new(message: "fixed it", apply: ->(prog) { prog })
    report = validate([StubCheck.new([error("boom", fix: fix, node: node)])], program(set(:x, 1)))

    assert_equal "fixed it (at game.rb:7)", report.warnings.first.full_message
  end

  # The "(at file:line)" suffix belongs to Finding#full_message, in one place. A
  # check that formats its own would double the location up, or print one where
  # full_message deliberately prints none. Read the checks for the literal rather
  # than arranging fourteen programs to trip them: this covers the whole set,
  # including a check written tomorrow.
  #
  # Both homes a check can have: the builtins, and an effect pack's own checks (which
  # register through the hook and produce findings the same way).
  def test_no_check_writes_a_location_into_its_own_message
    checks = Dir[File.expand_path("../lib/ruby_gba/ir/guardrails/*.rb", __dir__)] +
             Dir[File.expand_path("../lib/ruby_gba/effects/packs/*.rb", __dir__)]
    refute_empty checks, "the check files should be where this test looks for them"

    offenders = checks.select { |path| File.read(path).include?("(at ") }

    assert_empty offenders.map { |path| File.basename(path) },
                 "a check formats its own location; that belongs to Finding#full_message alone"
  end
end
