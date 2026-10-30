# frozen_string_literal: true

require "test_helper"
require "stringio"

# A game built for a browser, told which of its lines only the console can run. The steps a
# browser can run are said nothing about, so the finding is a list of exactly the lines in the
# way, each with its own words — not a lecture on the hardware.
class TestIRGuardrailWebPortability < Minitest::Test
  include VBlank::IR::Build
  Guardrails = VBlank::IR::Guardrails

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

  def test_the_web_build_stops_at_a_console_only_step_and_says_where
    said = StringIO.new
    error = assert_raises(Guardrails::ValidationError) do
      VBlank::IR::Backends::JS.new.refuse_console_only_steps!(mixed_program, said)
    end

    assert_match(/raw instructions/, error.message)
    refute_match(/which line the console's screen is drawing/, error.message,
                 "the reading in a routine nothing calls does not stop the build")
  end

  # A console-only step in a routine nothing calls never runs, so the web build leaves it out and
  # goes ahead, as the JavaScript lowering does — and still says the line, which stops the build
  # the day something calls it.
  def test_the_web_build_warns_of_a_console_only_step_nothing_calls
    said = StringIO.new
    program = program(screen(:bitmap), set(:x, 1), func(:later, set(:y, read_scanline)), halt)

    VBlank::IR::Backends::JS.new.refuse_console_only_steps!(program, said)

    assert_match(/which line the console's screen is drawing/, said.string)
    assert_match(/Nothing in the game calls/, said.string)
  end
end
