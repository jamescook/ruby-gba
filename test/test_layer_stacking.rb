# frozen_string_literal: true

require "test_helper"
require_relative "differential"

# Layers, as a PICTURE: what a declared stack actually changes about what you see.
#
# Every test here is built so declaration order and layer order DISAGREE — the thing
# that must end up on top is written first, so it would be underneath if the stack were
# being ignored. A test where the two orders agree proves nothing at all.
class TestLayerStacking < Minitest::Test
  include Differential

  RED = RubyGBA::Color.resolve(:red)
  BLUE = RubyGBA::Color.resolve(:blue)
  GREEN = RubyGBA::Color.resolve(:green)

  # Somewhere both sprites cover, and somewhere both backgrounds cover.
  OVERLAP_X = 104
  OVERLAP_Y = 64

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  def screen_of(prog, frames: 3)
    Reference.new.run(prog, max_steps: 400_000, frames: frames).screen
  end

  # Two sprites in the same spot, red written FIRST. Without a stack the blue one is
  # in front, because a sprite declared later sits on top.
  def two_sprites(stacked:)
    program do
      screen :tiled
      image(:red_guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:blue_guy, "#" => :blue) { (["#" * 8] * 8).join("\n") }

      if stacked
        layers :behind, :in_front
        layer(:in_front) { sprite :red_guy, at: [100, 60] }
        layer(:behind) { sprite :blue_guy, at: [100, 60] }
      else
        sprite :red_guy, at: [100, 60]
        sprite :blue_guy, at: [100, 60]
      end
      game_loop { nil }
    end
  end

  # Two full-screen backgrounds, red declared FIRST. Without a stack the blue one
  # covers it. `scrolled` picks which of the interpreter's two paths runs: a still
  # scene is stamped once, a scrolling one is recomposited every frame.
  def two_backgrounds(stacked:, scrolled: false)
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

  # --- sprites ---

  def test_without_a_stack_the_sprite_declared_last_is_in_front
    assert_equal BLUE, screen_of(two_sprites(stacked: false)).pixel(OVERLAP_X, OVERLAP_Y)
  end

  def test_a_stack_puts_the_front_layer_on_top_however_it_was_declared
    assert_equal RED, screen_of(two_sprites(stacked: true)).pixel(OVERLAP_X, OVERLAP_Y)
  end

  # The console composites sprites in hardware and the interpreter paints them itself,
  # so "they agree" is the only claim worth making about the stack. Whole-screen, not a
  # picked pixel: a stack applied to the wrong thing shows up somewhere.
  def test_both_backends_stack_sprites_the_same_way
    assert_backends_agree(two_sprites(stacked: true), frames: 3, name: "STKSPR")
  end

  # --- backgrounds, painted once ---

  def test_without_a_stack_the_background_declared_last_covers_the_others
    assert_equal BLUE, screen_of(two_backgrounds(stacked: false)).pixel(OVERLAP_X, OVERLAP_Y)
  end

  def test_a_stack_puts_the_front_background_on_top_however_it_was_declared
    assert_equal RED, screen_of(two_backgrounds(stacked: true)).pixel(OVERLAP_X, OVERLAP_Y)
  end

  def test_both_backends_stack_backgrounds_the_same_way
    assert_backends_agree(two_backgrounds(stacked: true), frames: 3, name: "STKBG")
  end

  # --- backgrounds, recomposited every frame ---

  # A scrolling scene takes the interpreter's other path: the whole view is rebuilt each
  # frame from the layers rather than stamped once. Both paths have to stack the same, or
  # a game looks right until something moves.
  def test_a_scrolling_scene_stacks_the_same_way_as_a_still_one
    assert_equal RED, screen_of(two_backgrounds(stacked: true, scrolled: true)).pixel(OVERLAP_X, OVERLAP_Y)
  end

  def test_both_backends_stack_a_scrolling_scene_the_same_way
    assert_backends_agree(two_backgrounds(stacked: true, scrolled: true), frames: 3, name: "STKSCR")
  end

  # --- the HUD, which is what started all this ---

  # A glyph lights only some of its 8x8 cell, so asking one pixel would answer about the
  # letter's shape rather than about the stack. Ask whether ANY of the cell shows the
  # text's color instead.
  def glyph_shows?(screen, x, y)
    (0...8).any? { |dy| (0...8).any? { |dx| screen.pixel(x + dx, y + dy) == RED } }
  end

  # A game with a red "X" of tiled text and a solid blue sprite over the same 8x8 cell.
  # Tiled text is drawn as hardware-sprite glyphs among the game's sprites, so the two
  # are competing for the same place in one order.
  def hud_over_sprite(stacked:)
    program do
      screen :tiled
      image(:blue_guy, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      if stacked
        layers :ui, :actors # the HUD is BEHIND the game here — unusual on purpose
        layer(:ui) { draw_text "X", 100, 60, :red }
        layer(:actors) { sprite :blue_guy, at: [100, 60] }
      else
        draw_text "X", 100, 60, :red # written BEFORE the sprite
        sprite :blue_guy, at: [100, 60]
      end
      game_loop { nil }
    end
  end

  # Written first and still on top: a HUD is drawn last whatever order it appears in.
  def test_a_hud_written_before_the_game_still_draws_over_it
    assert glyph_shows?(screen_of(hud_over_sprite(stacked: false)), 100, 60)
  end

  # ...unless a stack says otherwise, which is the whole point of naming the depths.
  def test_a_hud_put_in_a_layer_behind_the_game_goes_behind_it
    refute glyph_shows?(screen_of(hud_over_sprite(stacked: true)), 100, 60)
  end

  def test_both_backends_agree_about_a_hud_written_before_the_game
    assert_backends_agree(hud_over_sprite(stacked: false), frames: 3, name: "HUDORD")
  end

  def test_both_backends_agree_about_a_hud_put_behind_the_game
    assert_backends_agree(hud_over_sprite(stacked: true), frames: 3, name: "HUDLYR")
  end

  # --- what a stack does NOT do ---

  # A thing that named no layer keeps the place it had. Wrapping one part of a game in a
  # layer must not pick up and move a part that says nothing about layers.
  def test_a_sprite_that_names_no_layer_is_not_moved_by_one_that_does
    prog = program do
      screen :tiled
      image(:red_guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:blue_guy, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:green_guy, "#" => :green) { (["#" * 8] * 8).join("\n") }

      layers :behind, :in_front
      layer(:in_front) { sprite :red_guy, at: [100, 60] }
      layer(:behind) { sprite :blue_guy, at: [100, 60] }
      sprite :green_guy, at: [100, 60] # no layer: it was written last, it stays last
      game_loop { nil }
    end

    assert_equal GREEN, screen_of(prog).pixel(OVERLAP_X, OVERLAP_Y)
  end

  # --- the rule itself, where a picture cannot show it ---

  # The two claims about un-layered things are hard to read off a screen: that they hold
  # their exact places, and that the layered ones are rearranged only among the places
  # they already had.
  def test_the_rule_rearranges_only_the_things_that_named_a_layer
    items = [
      { name: :a, layer: nil },
      { name: :b, layer: :front },
      { name: :c, layer: nil },
      { name: :d, layer: :back },
    ]
    ordered = RubyGBA::IR::Stacking.order(items, %i[back front]) { |item| item[:layer] }

    assert_equal %i[a d c b], ordered.map { |item| item[:name] },
                 "a and c must not move; d and b swap into the places b and d had"
  end

  def test_a_layer_the_stack_never_named_does_not_move_anything
    items = [{ name: :a, layer: :ghost }, { name: :b, layer: nil }]
    ordered = RubyGBA::IR::Stacking.order(items, %i[back front]) { |item| item[:layer] }

    assert_equal %i[a b], ordered.map { |item| item[:name] }
  end

  def test_things_in_one_layer_keep_the_order_they_were_declared_in
    items = %i[first second third].map { |name| { name: name, layer: :only } }
    ordered = RubyGBA::IR::Stacking.order(items, [:only]) { |item| item[:layer] }

    assert_equal %i[first second third], ordered.map { |item| item[:name] }
  end
end
