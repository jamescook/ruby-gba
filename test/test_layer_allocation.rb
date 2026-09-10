# frozen_string_literal: true

require "test_helper"
require_relative "differential"

# What a stack becomes on the console: the arrangement that was impossible before, the
# limit that is loud when you reach it, and the report that says what the framework
# picked.
#
# The arrangement is a background IN FRONT OF a sprite — a fence the hero walks behind,
# grass that passes over their feet. Ordering sprites among sprites and backgrounds among
# backgrounds is one thing; putting one between two of the other is what needs the
# console's own stacking hardware, and what a picture can never fall into by accident.
class TestLayerAllocation < Minitest::Test
  include Differential

  Stacking = RubyGBA::IR::Stacking

  RED = RubyGBA::Color.resolve(:red)
  WHITE = RubyGBA::Color.resolve(:white)

  # Where the sprite and the fence both cover.
  SPOT_X = 104
  SPOT_Y = 64

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  def screen_of(prog, frames: 3)
    Reference.new.run(prog, max_steps: 400_000, frames: frames).screen
  end

  # A red hero standing under a white fence. `in_front` decides whether the fence layer
  # sits in front of the hero or behind it — the same program either way, so the only
  # thing that can change the picture is the stack.
  def hero_and_fence(in_front:)
    order = in_front ? %i[hero fence] : %i[fence hero]
    program do
      screen :tiled
      image(:post, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :posts, "#" => :post
      layers(*order)

      layer(:fence) { background :fence_bg, tiles: :posts, map: (0...20).map { "#" * 30 } }
      layer(:hero) { sprite :guy, at: [100, 60] }
      game_loop { nil }
    end
  end

  # --- the arrangement that needed the hardware ---

  def test_a_background_in_a_layer_in_front_of_a_sprite_covers_it
    assert_equal WHITE, screen_of(hero_and_fence(in_front: true)).pixel(SPOT_X, SPOT_Y)
  end

  def test_the_same_background_behind_the_sprite_does_not
    assert_equal RED, screen_of(hero_and_fence(in_front: false)).pixel(SPOT_X, SPOT_Y)
  end

  # The interpreter paints its picture itself; the console composites in hardware, from
  # two-bit priority fields. That they land on the same picture is the only claim worth
  # making, and it is the one this whole bead turns on.
  def test_both_backends_put_the_background_in_front_of_the_sprite
    assert_backends_agree(hero_and_fence(in_front: true), frames: 3, name: "FGLYR")
  end

  def test_both_backends_put_the_background_behind_the_sprite
    assert_backends_agree(hero_and_fence(in_front: false), frames: 3, name: "BGLYR")
  end

  # --- levels are spent on what needs them, not on names ---

  # The console keeps four levels and an author can name as many layers as they like. A
  # layer costs a level only when it holds scenery, because scenery is the one thing the
  # console cannot tell apart from other scenery any other way.
  def test_many_layers_share_the_few_levels_the_console_keeps
    prog = program do
      screen :tiled
      image(:tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      layers :sky, :enemies, :hero, :bullets, :ui

      layer(:sky) { background :bg, tiles: :set, map: (0...20).map { "#" * 30 } }
      layer(:enemies) { sprite :guy, at: [10, 10] }
      layer(:hero) { sprite :guy, at: [20, 20] }
      layer(:bullets) { sprite :guy, at: [30, 30] }
      layer(:ui) { draw_text "HI", 8, 8, :white }
      game_loop { nil }
    end

    assert_equal 1, Stacking.picture(prog).depths.count,
                 "five layers over one background need one level, not five"
  end

  def test_each_background_takes_a_level_of_its_own
    prog = program do
      screen :tiled
      image(:tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      layers :far, :near
      map = (0...20).map { "#" * 30 }
      layer(:far) { background :far_bg, tiles: :set, map: map }
      layer(:near) { background :near_bg, tiles: :set, map: map }
      game_loop { nil }
    end

    assert_equal 2, Stacking.picture(prog).depths.count
  end

  # --- the limit, spoken in the author's own names ---

  # Four backgrounds and a layer of sprites behind all of them needs five levels: the
  # sprites cannot share the backmost background's level, because on that level a sprite
  # is drawn in FRONT.
  def deep_stack
    program do
      screen :tiled
      image(:tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      layers :ghosts, :l1, :l2, :l3, :l4
      map = (0...20).map { "#" * 30 }

      layer(:ghosts) { sprite :guy, at: [10, 10] }
      layer(:l1) { background :bg1, tiles: :set, map: map }
      layer(:l2) { background :bg2, tiles: :set, map: map }
      layer(:l3) { background :bg3, tiles: :set, map: map }
      layer(:l4) { background :bg4, tiles: :set, map: map }
      game_loop { nil }
    end
  end

  def test_a_picture_deeper_than_the_console_stacks_is_refused
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(deep_stack) }

    assert_match(/needs 5 levels/, error.message)
    assert_match(/stacks 4/, error.message)
  end

  # The refusal has to name the layer that caused it, not a hardware register. It also
  # has to name the RIGHT cause: here it is the sprites behind everything, not the count
  # of backgrounds.
  def test_the_refusal_names_the_layer_that_cost_the_level
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(deep_stack) }

    assert_match(/:ghosts/, error.message)
    assert_match(/behind every background/, error.message)
    refute_match(/BG[0-3]/, error.message)
  end

  def test_the_refusal_shows_the_stack_that_was_declared
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(deep_stack) }

    assert_match(/:ghosts, :l1, :l2, :l3, :l4/, error.message)
  end

  # --- where "it named no layer" stops having an answer ---

  # A picture is normally scenery at the back and everything that moves in front, and
  # something that named no layer is left in that arrangement. Put a background in FRONT
  # of a sprite and that arrangement is gone, so there is nowhere to leave it.
  def test_a_thing_with_no_layer_is_refused_once_a_background_goes_in_front
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        image(:post, "#" => :white) { (["#" * 8] * 8).join("\n") }
        image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
        tiles :posts, "#" => :post
        layers :hero, :fence

        layer(:hero) { sprite :guy, at: [100, 60] }
        layer(:fence) { background :fence_bg, tiles: :posts, map: (0...20).map { "#" * 30 } }
        sprite :guy, at: [8, 8] # no layer, and now there is no answer for it
        game_loop { nil }
      end
    end

    assert_match(/name no layer/, error.message)
    assert_match(/put each one in a `layer` block/, error.message)
  end

  # The same program without the background in front is fine — a stack that only orders
  # sprites among sprites leaves the old arrangement intact, so partial adoption still
  # works. This is the test that keeps the refusal above from spreading.
  def test_a_thing_with_no_layer_is_left_alone_while_the_arrangement_holds
    prog = program do
      screen :tiled
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      layers :behind, :in_front
      layer(:in_front) { sprite :guy, at: [100, 60] }
      layer(:behind) { sprite :guy, at: [100, 60] }
      sprite :guy, at: [8, 8] # no layer, and it does not need one
      game_loop { nil }
    end

    assert_equal 3, prog.walk.count { |node| node.kind == :object }
  end

  # --- the report ---

  def test_the_report_says_what_each_layer_became
    rom = RubyGBA.build("STACKED", code: "BSTK", maker: "01") do
      screen :tiled
      image(:tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :tile
      layers :sky, :actors, :ui

      layer(:sky) { background :bg, tiles: :set, map: (0...20).map { "#" * 30 } }
      layer(:actors) { sprite :guy, at: [10, 10] }
      layer(:ui) { draw_text "HI", 8, 8, :white }
      game_loop { nil }
    end

    out = StringIO.new
    RubyGBA::BuildReport.render(rom, out: out)
    report = out.string

    assert_match(/the stack, back to front/, report)
    assert_match(/:sky\s+background :bg/, report)
    assert_match(/:actors\s+1 sprite/, report)
    assert_match(/:ui\s+2 sprites/, report)
    assert_match(/1 of 4 levels used, 3 free/, report)
  end

  def test_the_report_says_nothing_about_a_stack_a_game_never_declared
    rom = RubyGBA.build("PLAIN", code: "BPLN", maker: "01") do
      screen :bitmap
      fill_rect 0, 0, 10, 10, :red
      halt
    end

    out = StringIO.new
    RubyGBA::BuildReport.render(rom, out: out)

    refute_match(/the stack/, out.string)
  end
end
