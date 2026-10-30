# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test/all/vblank/builder/test_layer_stacking.rb whose games show two backgrounds at
# once, which a Game Boy Color's hardware cannot do, so they play on the Advance's runs alone. As
# there, each game is built so declaration order and layer order DISAGREE.
class TestLayerStackingOnTheAdvance < Minitest::Test
  include Differential

  RED = VBlank::Graphics::Color.resolve(:red)
  BLUE = VBlank::Graphics::Color.resolve(:blue)

  # Somewhere both backgrounds cover.
  OVERLAP_X = 104
  OVERLAP_Y = 64

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  private def screen_of(prog, frames: 3)
    game_player.run(prog, max_steps: 400_000, frames: frames).screen
  end

  # Two full-screen backgrounds, red declared FIRST. Without a stack the blue one
  # covers it. `scrolled` picks which of the interpreter's two paths runs: a still
  # scene is stamped once, a scrolling one is recomposited every frame.
  private def two_backgrounds(stacked:, scrolled: false)
    program do
      screen :tiled
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:blue_tile, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :reds, "." => :red_tile
      tiles :blues, "." => :blue_tile
      full = (0...32).map { "." * 32 }

      layers :behind, :in_front if stacked
      red = stacked ? layer(:in_front) { background :red_bg, tiles: :reds, map: full } : background(:red_bg, tiles: :reds, map: full)
      stacked ? layer(:behind) { background :blue_bg, tiles: :blues, map: full } : background(:blue_bg, tiles: :blues, map: full)
      red.scroll_to 0, 0 if scrolled
      game_loop { nil }
    end
  end

  # --- backgrounds, painted once ---

  def test_without_a_stack_the_background_declared_last_covers_the_others
    assert_equal BLUE, screen_of(two_backgrounds(stacked: false)).pixel(OVERLAP_X, OVERLAP_Y)
  end

  def test_a_stack_puts_the_front_background_on_top_however_it_was_declared
    assert_equal RED, screen_of(two_backgrounds(stacked: true)).pixel(OVERLAP_X, OVERLAP_Y)
  end

  # --- backgrounds, recomposited every frame ---

  # A scrolling scene takes the interpreter's other path: the whole view is rebuilt each
  # frame from the layers rather than stamped once. Both paths have to stack the same, or
  # a game looks right until something moves.
  def test_a_scrolling_scene_stacks_the_same_way_as_a_still_one
    assert_equal RED, screen_of(two_backgrounds(stacked: true, scrolled: true)).pixel(OVERLAP_X, OVERLAP_Y)
  end

  # --- the whole screen ---

  def test_both_backends_stack_backgrounds_the_same_way
    assert_backends_agree(two_backgrounds(stacked: true), frames: 3, name: "STKBG")
  end

  def test_both_backends_stack_a_scrolling_scene_the_same_way
    assert_backends_agree(two_backgrounds(stacked: true, scrolled: true), frames: 3, name: "STKSCR")
  end
end
