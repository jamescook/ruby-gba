# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# The first real guardrail: a program that draws but never turns the display on.
# This is the classic silent-black-screen footgun, caught on the IR before any
# ROM is built — detect, explain in plain language, and auto-fix by switching the
# screen on for you.
class TestIRGuardrailDisplayMode < Minitest::Test
  include RubyGBA::IR::Build

  Guardrails = RubyGBA::IR::Guardrails

  def test_drawing_without_a_display_mode_is_flagged
    report = Guardrails::Validator.new.run(program(pixel(10, 20, :red)), autofix: false)
    refute report.ok?
    assert_equal 1, report.errors.size
    message = report.errors.first.message
    assert_match(/black/i, message)
    assert_match(/display/i, message)
  end

  def test_autofix_switches_the_screen_on_and_warns
    report = Guardrails::Validator.new.run(program(pixel(10, 20, :red)))

    assert report.ok?, "auto-fixing should leave no errors"
    assert_equal 1, report.warnings.size
    assert_match(/bitmap/i, report.warnings.first.message)

    first = report.program.children.first
    assert_equal :display, first.kind
    assert_equal :bitmap, first[:mode]
    assert_equal :pixel, report.program.children[1].kind # original draw preserved
  end

  def test_the_fixed_program_is_clean_on_a_second_pass
    fixed = Guardrails::Validator.new.run(program(pixel(10, 20, :red))).program
    report = Guardrails::Validator.new.run(fixed)
    assert report.ok?
    assert_empty report.findings
  end

  def test_a_program_that_already_sets_a_mode_is_left_alone
    report = Guardrails::Validator.new.run(program(display(:bitmap), clear_screen(:blue)))
    assert report.ok?
    assert_empty report.findings
  end

  def test_a_program_that_never_draws_is_not_nagged
    report = Guardrails::Validator.new.run(program(set(:x, 1), loop_(add(:x, 1))), autofix: false)
    assert report.ok?
    assert_empty report.findings
  end

  def test_clear_screen_counts_as_drawing
    report = Guardrails::Validator.new.run(program(clear_screen(:blue)), autofix: false)
    refute report.ok?
  end
end
