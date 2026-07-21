# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"

# The first real guardrail: a program that draws but never turns the display on.
# This is the classic silent-black-screen footgun, caught on the IR before any
# ROM is built — detect, explain in plain language, and auto-fix by switching the
# screen on for you.
class TestIRGuardrailDisplayMode < Minitest::Test
  include RubyGBA::IR::Build

  Guardrails = RubyGBA::IR::Guardrails

  # A validator running only the display-mode check, so these unit tests assert it
  # in isolation. The tiny fixtures here (a lone pixel, no halt) would also trip
  # the vblank and termination guardrails, which aren't what's under test.
  def display_validator
    Guardrails::Validator.new(checks: [Guardrails::Checks::DisplayModeSet.new])
  end

  def test_drawing_without_a_display_mode_is_flagged
    report = display_validator.run(program(pixel(10, 20, :red)), autofix: false)
    refute report.ok?
    assert_equal 1, report.errors.size
    message = report.errors.first.message
    assert_match(/black/i, message)
    assert_match(/display/i, message)
  end

  def test_autofix_switches_the_screen_on_and_warns
    report = display_validator.run(program(pixel(10, 20, :red)))

    assert report.ok?, "auto-fixing should leave no errors"
    assert_equal 1, report.warnings.size
    assert_match(/bitmap/i, report.warnings.first.message)

    first = report.program.children.first
    assert_equal :display, first.kind
    assert_equal :bitmap, first[:mode]
    assert_equal :pixel, report.program.children[1].kind # original draw preserved
  end

  def test_the_fixed_program_is_clean_on_a_second_pass
    fixed = display_validator.run(program(pixel(10, 20, :red))).program
    report = display_validator.run(fixed)
    assert report.ok?
    assert_empty report.findings
  end

  def test_a_program_that_already_sets_a_mode_is_left_alone
    report = display_validator.run(program(display(:bitmap), clear_screen(:blue)))
    assert report.ok?
    assert_empty report.findings
  end

  def test_a_program_that_never_draws_is_not_nagged
    report = display_validator.run(program(set(:x, 1), loop_(add(:x, 1))), autofix: false)
    assert report.ok?
    assert_empty report.findings
  end

  def test_clear_screen_counts_as_drawing
    report = display_validator.run(program(clear_screen(:blue)), autofix: false)
    refute report.ok?
  end

  # This is a fatal footgun (a guaranteed black screen), so at build time it stops
  # the build rather than shipping silently — with the explanation and suggested
  # fix on the err stream. Nothing is auto-corrected.
  def test_build_halts_on_a_draw_without_a_display_mode
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("BLACK", code: "BBLK", maker: "01", out: StringIO.new, err: err) do
        clear_screen :blue
        halt
      end
    end
    assert_match(/display/i, err.string, "the explanation names the missing display mode")
    assert_match(/black/i, err.string, "and what goes wrong")
  end
end
