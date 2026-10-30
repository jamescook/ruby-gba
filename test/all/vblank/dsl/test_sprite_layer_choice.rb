# frozen_string_literal: true

require "test_helper"

# A SPRITE THAT CHANGES WHICH LAYER IT IS IN while the game runs: what `put_in_layer` refuses.
#
# Where it is drawn is in test/console/gba/vblank/dsl/test_sprite_layer_choice_on_the_advance.rb.
# Those games stand a hero between two backgrounds at once, a floor and an arch, so he has a
# layer to be in front of and one to be behind; a Game Boy Color shows one background at a time,
# so they play on the Advance's runs alone.
class TestSpriteLayerChoice < Minitest::Test
  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # --- what it refuses ---

  private def build_error(&block)
    assert_raises(ArgumentError) { program(&block) }
  end

  def test_a_layer_the_stack_does_not_have_is_refused_and_the_stack_is_shown
    error = build_error do
      screen :tiled
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :ground, :upper
      hero = layer(:upper) { sprite :guy, at: [0, 0] }
      game_loop { hero.put_in_layer :stairz }
    end

    assert_match(/no layer of that name/, error.message)
    assert_match(/:ground, :upper/, error.message)
  end

  def test_a_game_with_no_stack_is_told_to_declare_one
    error = build_error do
      screen :tiled
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      hero = sprite :guy, at: [0, 0]
      game_loop { hero.put_in_layer :upper }
    end

    assert_match(/declares no layers/, error.message)
  end

  def test_several_layers_with_nothing_to_pick_between_them_are_refused
    error = build_error do
      screen :tiled
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :ground, :upper
      hero = layer(:upper) { sprite :guy, at: [0, 0] }
      game_loop { hero.put_in_layer %i[ground upper] }
    end

    assert_match(/showing:/, error.message)
  end

  def test_one_layer_with_showing_is_told_to_give_a_list
    error = build_error do
      screen :tiled
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :ground, :upper
      hero = layer(:upper) { sprite :guy, at: [0, 0] }
      floor = var :floor, 0
      game_loop { hero.put_in_layer :ground, showing: floor }
    end

    assert_match(/names one layer/, error.message)
  end

  def test_a_sprite_on_a_bitmap_screen_is_told_it_has_no_layers_to_move_between
    error = build_error do
      screen :bitmap
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :ground, :upper
      hero = layer(:upper) { sprite :guy, at: [0, 0] }
      game_loop { hero.put_in_layer :ground }
    end

    assert_match(/screen :tiled/, error.message)
  end
end
