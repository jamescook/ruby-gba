# frozen_string_literal: true

require "test_helper"

# What a status bar cannot share the display with. On the Advance the bar is kept to its rows by
# the display's windows, which a light and the fades held to part of the picture use too. On the
# Color the bar uses the memory a painted screen keeps its picture in, and a sprite behind a
# background is behind the bar there too.
class TestIRGuardrailStatusBarCannotShare < Minitest::Test
  Guardrails = VBlank::IR::Guardrails

  private def validator = Guardrails::Validator.new(checks: [Guardrails::Checks::StatusBarCannotShare.new])

  # A game on +console+ with a field and a status bar, and whatever +more+ adds.
  private def bar_program(console, &more)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: console))
    b.instance_eval do
      screen :tiled
      image(:i_blue, "#" => :blue) { "########\n" * 8 }
      image(:ball, "#" => :white) { "########\n" * 8 }
      tiles :t, "#" => :i_blue
      instance_eval(&more) if more
      game_loop {}
    end
    b.finalize_program
    b.program
  end

  private def refusal(program) = validator.run(program, autofix: false).errors.first&.message

  def test_a_bar_and_a_fade_held_to_a_rectangle_on_the_advance_are_refused
    program = bar_program(:gba) do
      background :field, tiles: :t, map: ["#" * 20]
      status_bar :score, tiles: :t, map: ["#" * 20], top: 100
      fade :black, 50, inside: [0, 0, 40, 40]
    end

    assert_match(/status bar :score and a fade held to part of the screen/, refusal(program))
  end

  def test_a_bar_and_a_painted_screen_on_the_color_are_refused
    program = bar_program(:gbc) do
      background :field, tiles: :t, map: ["#" * 20]
      status_bar :score, tiles: :t, map: ["#" * 20], top: 100
      scene(:title) { screen :bitmap }
    end

    assert_match(/status bar :score and a `screen :bitmap`/, refusal(program))
  end

  def test_a_sprite_behind_a_background_beside_a_bar_on_the_color_is_refused
    program = bar_program(:gbc) do
      layers :back, :world
      layer(:back) { sprite :ball, at: [10, 10] }
      layer(:world) { background :field, tiles: :t, map: ["#" * 20] }
      status_bar :score, tiles: :t, map: ["#" * 20], top: 100
    end

    assert_match(/put the sprite :ball behind a background/, refusal(program))
  end

  # The same game on the Advance, where a sprite behind the field is still over the bar.
  def test_a_sprite_behind_a_background_beside_a_bar_on_the_advance_fits
    program = bar_program(:gba) do
      layers :back, :world
      layer(:back) { sprite :ball, at: [10, 10] }
      layer(:world) { background :field, tiles: :t, map: ["#" * 20] }
      status_bar :score, tiles: :t, map: ["#" * 20], top: 100
    end

    assert_nil refusal(program)
  end
end
