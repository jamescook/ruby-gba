# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"

# The guardrail extension hook: Guardrails.register lets something outside the
# frozen builtins contribute a whole-program check (an effect pack's own footgun
# guardrails, or a one-off a game registers), and the validation pass picks it up
# from then on. These tests exercise the registry and prove a registered check
# runs on the real build path — with the same Finding/Fix contract the builtins
# use — and stops running once cleared.
class TestGuardrailRegistry < Minitest::Test
  include RubyGBA::IR::Build

  Guardrails = RubyGBA::IR::Guardrails

  # A whole-program check that errors when the program sets a variable named
  # :boom — a stand-in for a pack check that inspects the built IR.
  class BoomCheck
    def detect(program)
      hit = program.each.any? { |node| node.kind == :set && node[:var] == :boom }
      return [] unless hit

      [Guardrails::Finding.new(check: :boom, severity: :error, message: "boom found", fix: nil)]
    end
  end

  # A check that simply reports whatever it was handed (for the Fix path).
  class StubCheck
    def initialize(findings)
      @findings = findings
    end

    def detect(_program)
      @findings
    end
  end

  # Global registry — clear it after every test so one test can't leak into the
  # next (or into other files' builds).
  def teardown
    Guardrails.clear_registered!
  end

  def test_register_returns_the_check_and_lists_it
    check = BoomCheck.new
    assert_same check, Guardrails.register(check)
    assert_includes Guardrails.registered_checks, check
  end

  def test_default_checks_are_the_builtins_plus_whatever_is_registered
    check = BoomCheck.new
    Guardrails.register(check)

    assert_includes Guardrails.default_checks, check
    Guardrails::BUILTIN_CHECKS.each do |builtin|
      assert_includes Guardrails.default_checks, builtin, "builtins stay in the default set"
    end
  end

  def test_a_registered_check_runs_in_the_default_validation_pass
    Guardrails.register(BoomCheck.new)
    report = Guardrails::Validator.new.run(program(set(:boom, 1)), autofix: false)
    assert_includes report.findings.map(&:check), :boom, "the default pass picked up the registered check"
  end

  def test_a_registered_checks_fix_is_applied_like_any_builtin
    replacement = program(set(:fixed, 1))
    fix = Guardrails::Fix.new(message: "fixed it", apply: ->(_prog) { replacement })
    Guardrails.register(StubCheck.new([Guardrails::Finding.new(check: :stub, severity: :error,
                                                               message: "boom", fix: fix)]))

    # Run only the registered checks so builtin findings don't cloud the assertion.
    report = Guardrails::Validator.new(checks: Guardrails.registered_checks).run(program(set(:x, 1)))
    assert report.ok?, "a fixed problem should not leave an error"
    assert_equal ["fixed it"], report.warnings.map(&:message)
    assert_same replacement, report.program
  end

  def test_registering_the_same_check_twice_keeps_a_single_copy
    check = BoomCheck.new
    Guardrails.register(check)
    Guardrails.register(check)
    assert_equal 1, Guardrails.registered_checks.count(check)
  end

  def test_registered_checks_hands_back_a_copy_callers_cannot_mutate
    Guardrails.register(BoomCheck.new)
    Guardrails.registered_checks.clear
    refute_empty Guardrails.registered_checks, "the internal registry is untouched"
  end

  def test_clearing_drops_registered_checks_back_to_builtins
    Guardrails.register(BoomCheck.new)
    Guardrails.clear_registered!
    assert_empty Guardrails.registered_checks
    assert_equal Guardrails::BUILTIN_CHECKS, Guardrails.default_checks
  end

  # --- the real build path consults the registry ---

  def test_a_registered_error_check_stops_a_build
    Guardrails.register(BoomCheck.new)
    err = StringIO.new

    ex = assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("BOOM", code: "BBOM", maker: "01", err: err) do
        screen :bitmap
        set :boom, 1
        halt
      end
    end

    assert_match(/stopped/, ex.message)
    assert_match(/boom found/, err.string, "the check's explanation reached the person")
  end

  def test_a_registered_check_leaves_a_clean_build_alone
    # The same check registered, but this program never trips it — so no false
    # positive, and the build succeeds.
    Guardrails.register(BoomCheck.new)
    rom = RubyGBA.build("CLEAN", code: "BCLN", maker: "01", err: StringIO.new) do
      screen :bitmap
      clear_screen :blue
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_without_registration_the_check_never_runs
    # No register call here: a program that would trip BoomCheck builds fine,
    # proving a check is active only while it's loaded.
    rom = RubyGBA.build("NOREG", code: "BNRG", maker: "01", err: StringIO.new) do
      screen :bitmap
      set :boom, 1
      clear_screen :blue
      halt
    end
    assert_operator rom.size, :>, 0
  end
end
