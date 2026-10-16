# frozen_string_literal: true

require "test_helper"

# A spotlight beside something that needs the same part of the display: a see-through
# layer, a fade placed in the stack, a bitmap screen, or no frames to work the light out
# before. Each is refused; a plain fade beside a light is not.
class TestIrGuardrailLightCannotShare < Minitest::Test
  runs_on :reference, :native
  Check = RubyGBA::IR::Guardrails::Checks::LightCannotShare

  # A tiled room with a light, and +said+ run before the loop. +loop+ false leaves the game
  # with no frames.
  private def findings(loop: true, &said)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      layers :ground, :water, :ui
      image(:tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      layer(:ground) { background :room, tiles: :set, map: ["#" * 32] * 20 }
      layer(:ui) { sprite :score, at: [8, 8], facing: { right: :tile } }
      spotlight at: [120, 80], radius: 40
      instance_exec(&said) if said
      game_loop { nil } if loop
    end
    builder.finalize_program
    Check.new.detect(builder.program)
  end

  def test_a_light_alone_or_beside_a_plain_fade_is_fine
    assert_empty findings
    assert_empty findings { fade :black, 50 }
  end

  def test_a_light_beside_a_see_through_layer_is_an_error
    found = findings do
      layer(:water, transparency: 40) { background :pond, tiles: :set, map: ["#" * 32] * 20 }
    end

    assert_equal [:light_cannot_share], found.map(&:check)
    assert_predicate found.first, :error?
    assert_match(/:water is see-through/, found.first.message)
  end

  def test_a_light_beside_a_placed_fade_is_an_error
    found = findings { fade :black, 50, under: :ui }

    assert_equal [:light_cannot_share], found.map(&:check)
    assert_match(/remove `under: :ui`/, found.first.message)
  end

  def test_a_light_in_a_game_that_shows_a_bitmap_screen_is_an_error
    found = findings do
      scene(:title) { screen :bitmap }
      case_var(:mode) { when_val 0, :title }
    end

    assert_match(/screen :bitmap/, found.map(&:message).join)
  end

  def test_a_light_with_no_frames_is_an_error
    found = findings(loop: false)

    assert_equal [:light_cannot_share], found.map(&:check)
    assert_match(/no `game_loop`/, found.first.message)
  end
end
