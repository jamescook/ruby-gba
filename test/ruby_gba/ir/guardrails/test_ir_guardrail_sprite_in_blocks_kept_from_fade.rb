# frozen_string_literal: true

require "test_helper"

# A sprite a placed fade is kept off, in a game that also shows that sprite in blocks.
#
# The console keeps a sprite out of a fade by the shape it was drawn in, and a sprite in
# blocks has another shape, so this is the one mix of a fade and blocks that is refused.
# What matters as much is what is NOT refused: the same two verbs wherever the fade holds
# nothing off by its shape.
class TestIrGuardrailSpriteInBlocksKeptFromFade < Minitest::Test
  runs_on :reference

  Check = RubyGBA::IR::Guardrails::Checks::SpriteInBlocksKeptFromFade

  # A cloud far off, a hero in the game and a score over it, each a sprite in a layer of
  # its own, with +said+ run before the loop.
  def findings(&said)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      layers :world, :actors, :ui
      image(:dot, "#" => :red) { (["########"] * 8).join("\n") }
      layer(:world) { sprite :cloud, at: [90, 20], facing: { right: :dot } }
      layer(:actors) { sprite :hero, at: [40, 40], facing: { right: :dot } }
      layer(:ui) { sprite :score, at: [8, 8], facing: { right: :dot } }
      instance_exec(&said)
      game_loop { nil }
    end
    builder.finalize_program
    Check.new.detect(builder.program)
  end

  def test_a_kept_sprite_that_is_in_blocks_is_an_error_that_says_what_to_write
    found = findings do
      pixelate 6
      fade :black, 50, under: :ui
    end

    assert_equal [:sprite_in_blocks_kept_from_fade], found.map(&:check)
    assert_predicate found.first, :error?
    assert_match(/under the layer :ui/, found.first.message)
    assert_match(/pixelate \.\.\., under: :ui/, found.first.message)
  end

  def test_a_place_for_the_blocks_that_still_reaches_the_kept_sprite_is_an_error_too
    found = findings do
      pixelate 6, under: :ui
      fade :black, 50, under: :actors
    end

    assert_equal [:sprite_in_blocks_kept_from_fade], found.map(&:check)
  end

  def test_keeping_the_same_things_out_of_both_is_fine
    assert_empty(findings do
      pixelate 6, under: :ui
      fade :black, 50, under: :ui
    end)
  end

  # A fade that keeps every sprite, or reaches every sprite, holds nothing off by its shape.
  def test_a_fade_whose_line_does_not_fall_between_the_sprites_is_fine
    assert_empty(findings do
      pixelate 6
      fade :black, 50, under: :world
    end)
    assert_empty(findings do
      pixelate 6
      fade :black, 50
    end)
  end

  def test_a_placed_fade_with_no_blocks_is_fine
    assert_empty(findings { fade :black, 50, under: :ui })
  end
end
