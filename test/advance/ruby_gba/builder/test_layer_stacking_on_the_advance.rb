# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test_layer_stacking.rb whose games show two backgrounds at once, which a Game Boy
# Color's hardware cannot do, so they play on the Advance's runs alone.
class TestLayerStackingOnTheAdvance < Minitest::Test
  include Differential

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
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

  def test_both_backends_stack_backgrounds_the_same_way
    assert_backends_agree(two_backgrounds(stacked: true), frames: 3, name: "STKBG")
  end

  def test_both_backends_stack_a_scrolling_scene_the_same_way
    assert_backends_agree(two_backgrounds(stacked: true, scrolled: true), frames: 3, name: "STKSCR")
  end
end
