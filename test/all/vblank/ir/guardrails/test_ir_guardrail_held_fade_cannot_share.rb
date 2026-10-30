# frozen_string_literal: true

require "test_helper"

# A fade held to a rectangle beside something that needs the same part of the display: a light,
# a see-through layer, or a fade placed in the stack. Each is refused; a plain fade or a tint
# beside a held one is not.
class TestIrGuardrailHeldFadeCannotShare < Minitest::Test
  Check = VBlank::IR::Guardrails::Checks::HeldFadeCannotShare

  # A tiled room with a fade held to its top half, and +said+ run before the loop.
  private def findings(&said)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      layers :ground, :water, :ui
      image(:tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      layer(:ground) { background :room, tiles: :set, map: ["#" * 32] * 20 }
      layer(:ui) { sprite :score, at: [8, 8], facing: { right: :tile } }
      fade :black, 50, inside: [0, 0, 240, 80]
      instance_exec(&said) if said
      game_loop { nil }
    end
    builder.finalize_program
    Check.new.detect(builder.program)
  end

  def test_a_held_fade_alone_or_beside_a_plain_fade_or_a_tint_is_fine
    assert_empty findings
    assert_empty findings { fade :white, 30 }
    assert_empty findings { tint :red, 40 }
  end

  def test_a_held_fade_beside_a_light_is_an_error
    found = findings { spotlight at: [120, 80], radius: 40 }

    assert_equal [:held_fade_cannot_share], found.map(&:check)
    assert_predicate found.first, :error?
    assert_match(/light/, found.first.message)
  end

  def test_a_held_fade_beside_a_see_through_layer_is_an_error
    found = findings do
      layer(:water, transparency: 40) { background :pond, tiles: :set, map: ["#" * 32] * 20 }
    end

    assert_equal [:held_fade_cannot_share], found.map(&:check)
    assert_match(/:water is see-through/, found.first.message)
  end

  def test_a_held_fade_beside_a_placed_fade_is_an_error
    found = findings { fade :black, 50, under: :ui }

    assert_equal [:held_fade_cannot_share], found.map(&:check)
    assert_match(/under: :ui/, found.first.message)
  end
end
