# frozen_string_literal: true

require "test_helper"

# A game built for a browser, told which of its lines only the console can run. The steps a
# browser can run are said nothing about, so the finding is a list of exactly the lines in the
# way, each with its own words — not a lecture on the hardware.
class TestIRGuardrailWebPortability < Minitest::Test
  include RubyGBA::IR::Build
  Guardrails = RubyGBA::IR::Guardrails

  NOP = [0xE1A00000].pack("V")

  # Ordinary steps, a raw instruction among them, and a reading of the display's line, one of
  # them in a routine nothing calls: a console-only step there would never run in a browser,
  # and is still a line the author has to look at before the game is meant for one.
  private def mixed_program
    program(screen(:bitmap), set(:x, 1), add(:x, 2), raw(NOP), fill_rect(0, 0, 8, 8, :red),
            func(:later, set(:y, read_scanline)), halt)
  end

  private def findings_of(program, severity: :warning)
    Guardrails::Validator.new(checks: [Guardrails::Checks::WebPortability.new(severity: severity)])
                         .run(program, autofix: false).findings
  end

  def test_each_console_only_step_is_named_and_nothing_else
    found = findings_of(mixed_program)

    assert_equal %i[raw read_scanline], found.map { |finding| finding.node.kind }
    assert(found.all?(&:warning?), "a cartridge build still goes ahead")
  end

  def test_each_finding_says_what_the_step_is_and_what_to_write_instead
    raw_finding, scanline_finding = findings_of(mixed_program)

    assert_match(/raw instructions/, raw_finding.message)
    assert_match(/cannot be built for the web/, raw_finding.message)
    assert_match(/framework's own words/, raw_finding.message)
    assert_match(/frame count/, scanline_finding.message)
  end

  def test_a_program_of_portable_steps_is_quiet
    assert_empty findings_of(program(screen(:bitmap), set(:x, 1), fill_rect(0, 0, 8, 8, :red), halt))
  end
end
