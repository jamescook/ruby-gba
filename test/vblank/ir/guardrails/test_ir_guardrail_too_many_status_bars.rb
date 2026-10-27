# frozen_string_literal: true

require "test_helper"

# A status bar covers the screen from its top row to the bottom, so one shows at a time. On the
# Advance it is one of the four background layers and counts against them; on the Color it is a
# layer of its own beside the one background, and does not.
class TestIRGuardrailTooManyStatusBars < Minitest::Test
  Guardrails = VBlank::IR::Guardrails

  private def validator
    Guardrails::Validator.new(checks: [Guardrails::Checks::TooManyStatusBars.new,
                                       Guardrails::Checks::TooManyBackgroundLayers.new])
  end

  # A game on +console+ with a field and the bars named, and whatever +more+ adds.
  private def bar_program(console, bars, &more)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: console))
    b.instance_eval do
      screen :tiled
      image(:i_blue, "#" => :blue) { "########\n" * 8 }
      tiles :t, "#" => :i_blue
      background :field, tiles: :t, map: Array.new(20) { "#" * 20 }
      bars.each { |name| status_bar name, tiles: :t, map: ["#" * 20], top: 100 }
      instance_eval(&more) if more
      game_loop {}
    end
    b.finalize_program
    b.program
  end

  def test_two_status_bars_on_one_screen_are_refused
    report = validator.run(bar_program(:gba, %i[score lives]), autofix: false)

    refute report.ok?
    message = report.errors.first.message
    assert_match(/2 status bars at one time/, message)
    assert_match(/:score, :lives/, message)
  end

  def test_a_bar_beside_the_one_background_of_the_color_fits
    report = validator.run(bar_program(:gbc, %i[score]), autofix: false)

    assert report.ok?, report.errors.map(&:message).join("\n")
  end

  def test_a_bar_takes_one_of_the_advances_four_layers
    program = bar_program(:gba, %i[score]) do
      %i[far middle near].each { |name| background name, tiles: :t, map: ["#" * 20] }
    end
    report = validator.run(program, autofix: false)

    refute report.ok?
    assert_match(/shows 5 scrolling backgrounds/, report.errors.first.message)
  end
end
