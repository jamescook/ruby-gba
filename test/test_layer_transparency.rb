# frozen_string_literal: true

require "test_helper"
require "differential"
require "stringio"

# SEEING THROUGH A LAYER TO WHAT IS BEHIND IT — water, glass, fog, a dimmed backdrop
# behind a menu.
#
# The author says it where the layer is opened (`layer :water, transparency: 40`) and
# never learns which of the console's two mechanisms carried it. A layer of SCENERY is
# blended by the display's own effect unit; a layer of SPRITES carries a bit in each
# sprite's own table entry. Same keyword, and these prove the same picture.
#
# What it MEANS is what it looks like: whatever sits directly under the layer at a pixel
# shows through it, anything in front draws solid, and where the layer has a see-through
# tile what is behind shows plain. Every one of those is what a reader guesses and also
# what the console does, so the tests below read as the picture rather than as a rule.
class TestLayerTransparency < Minitest::Test
  include Differential

  SOLID_TILE = (("#" * 8) + "\n").freeze * 8

  RED = RubyGBA::Color.resolve(:red)
  WHITE = RubyGBA::Color.resolve(:white)
  GREEN = RubyGBA::Color.resolve(:green)

  # White over red, half way: each channel takes half of each side and the sixteenth is
  # dropped once, from the sum. Named rather than derived — it is the number the console
  # was measured to give, and deriving it would let a wrong rule move both sides.
  HALF_WHITE_OVER_RED = 0x3DFF

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # A red floor with a white pane over it, the pane's layer see-through by +amount+.
  def scenery_program(amount)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:back, "#" => :red) { tile }
      image(:front, "#" => :white) { tile }
      tiles :backset, "#" => :back
      tiles :frontset, "#" => :front
      layers :deep, :glass
      layer(:deep) { background :floor, tiles: :backset, map: Array.new(20) { "#" * 30 } }
      layer(:glass, transparency: amount) do
        background :pane, tiles: :frontset, map: Array.new(20) { "#" * 30 }
      end
      game_loop { wait_vblank }
    end
  end

  # The same picture with the front layer a SPRITE instead — the other mechanism, and the
  # author writes the same thing.
  def sprite_program(amount)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:back, "#" => :red) { tile }
      image(:ghost, "#" => :white) { tile }
      tiles :backset, "#" => :back
      layers :deep, :spooks
      layer(:deep) { background :floor, tiles: :backset, map: Array.new(20) { "#" * 30 } }
      layer(:spooks, transparency: amount) { sprite :ghost, at: [64, 64] }
      game_loop { wait_vblank }
    end
  end

  SCENERY_XY = [8, 8].freeze
  SPRITE_XY = [66, 66].freeze

  def shown(program, x, y)
    Reference.new.run(program, frames: 2).screen.pixel(x, y)
  end

  def console(program, x, y, name)
    assert_gemba_loads_rom(assemble_rom(program, name: name), frames: 6).pixel_gba(x, y)
  end

  # --- the picture ---

  def test_a_see_through_layer_of_scenery_shows_what_is_behind_it
    seen = [0, 50, 100].map { |amount| shown(scenery_program(amount), *SCENERY_XY) }

    assert_equal [WHITE, HALF_WHITE_OVER_RED, RED], seen
  end

  def test_a_see_through_layer_of_sprites_shows_what_is_behind_it
    seen = [0, 50, 100].map { |amount| shown(sprite_program(amount), *SPRITE_XY) }

    assert_equal [WHITE, HALF_WHITE_OVER_RED, RED], seen
  end

  # A sprite is see-through where its own pixels are; the scenery beside it is not. The
  # two mechanisms differ most here, and this is what says the sprite path picks out
  # exactly the sprites in that layer rather than blending the screen.
  def test_only_the_see_through_layer_blends
    screen = Reference.new.run(sprite_program(50), frames: 2).screen

    assert_equal HALF_WHITE_OVER_RED, screen.pixel(*SPRITE_XY), "the sprite blends"
    assert_equal RED, screen.pixel(*SCENERY_XY), "the floor beside it does not"
  end

  # --- and the console agrees, which is the point of having two backends ---

  def test_the_console_blends_a_see_through_layer_of_scenery_the_same
    [0, 50, 100].each_with_index do |amount, i|
      assert_equal [WHITE, HALF_WHITE_OVER_RED, RED][i],
                   console(scenery_program(amount), *SCENERY_XY, "SEEBG"),
                   "at #{amount} see-through the scenery disagrees"
    end
  end

  def test_the_console_blends_a_see_through_layer_of_sprites_the_same
    [0, 50, 100].each_with_index do |amount, i|
      assert_equal [WHITE, HALF_WHITE_OVER_RED, RED][i],
                   console(sprite_program(amount), *SPRITE_XY, "SEEOBJ"),
                   "at #{amount} see-through the sprite disagrees"
    end
  end

  # The whole screen, not the two pixels above — a blend that reached the wrong layer, or
  # the wrong pixels of the right one, shows up here and nowhere else.
  def test_the_two_backends_draw_the_same_see_through_screen
    assert_backends_agree(scenery_program(40), frames: 2)
    assert_backends_agree(sprite_program(40), frames: 2)
  end

  # A see-through layer is a standing property of the picture, not something done each
  # frame, so it must not drift as the game runs.
  def test_the_blend_holds_frame_after_frame
    program = sprite_program(50)

    assert_equal HALF_WHITE_OVER_RED,
                 assert_gemba_loads_rom(assemble_rom(program, name: "SEEHLD"), frames: 40).pixel_gba(*SPRITE_XY)
  end

  # --- what it refuses ---

  def test_an_amount_outside_the_range_says_the_range
    error = assert_raises(ArgumentError) { scenery_program(140) }

    assert_includes error.message, "0 to 100"
  end

  def test_an_amount_the_game_works_out_is_refused_by_name
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        layers :glass
        level = var :level, 40
        layer(:glass, transparency: level) { sprite :x, at: [0, 0] }
      end
    end

    assert_includes error.message, "whole number"
  end

  def test_a_bitmap_screen_is_refused_and_says_why
    error = assert_raises(ArgumentError) do
      program do
        screen :bitmap
        layers :glass
        layer(:glass, transparency: 40) { nil }
      end
    end

    assert_includes error.message, "screen :tiled"
  end

  # A game has one see-through layer, and the message names the one it already has.
  def test_a_second_see_through_layer_is_refused
    tile = SOLID_TILE
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        image(:art, "#" => :white) { tile }
        layers :water, :jellyfish
        layer(:water, transparency: 40) { sprite :art, at: [0, 0] }
        layer(:jellyfish, transparency: 40) { sprite :art, at: [8, 8] }
      end
    end

    assert_includes error.message, ":water"
    assert_includes error.message, ":jellyfish"
    assert_includes error.message, "one see-through layer"
  end

  # Two blocks for the same layer that disagree about the amount. Saying the SAME amount
  # twice is fine — it is the same fact said twice, not two facts.
  def test_the_same_layer_asked_for_two_amounts_is_refused
    tile = SOLID_TILE
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        image(:art, "#" => :white) { tile }
        layers :water
        layer(:water, transparency: 40) { sprite :art, at: [0, 0] }
        layer(:water, transparency: 70) { sprite :art, at: [8, 8] }
      end
    end

    assert_includes error.message, "one time"
  end

  def test_the_same_amount_said_twice_is_fine
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:art, "#" => :white) { tile }
      layers :water
      layer(:water, transparency: 40) { sprite :art, at: [0, 0] }
      layer(:water, transparency: 40) { sprite :art, at: [8, 8] }
    end
  end

  # --- the guardrail ---

  def warnings(program)
    RubyGBA::IR::Guardrails::Validator.new.run(program, autofix: false).warnings.map(&:check)
  end

  def test_a_layer_nobody_can_see_is_a_warning
    assert_includes warnings(scenery_program(100)), :layer_invisible
  end

  def test_a_layer_you_can_partly_see_is_a_style_choice
    refute_includes warnings(scenery_program(60)), :layer_invisible
  end

  # --- what it costs ---

  # Nothing. The display blends as it draws, so a see-through layer costs the same as the
  # same layer drawn solid — which is the whole bargain of the tiled screen.
  def test_seeing_through_a_layer_costs_nothing
    solid = RubyGBA::IR::CostModel.new.steady_cost(scenery_program(0))
    blended = RubyGBA::IR::CostModel.new.steady_cost(scenery_program(40))

    assert_in_delta solid, blended, 0.0001
  end

  def test_the_report_says_which_layer_is_see_through
    out = StringIO.new
    RubyGBA::IR::CostModel.new.render(scenery_program(40), out: out, color: false)

    assert_includes out.string, ":glass is 40 see-through"
  end
end
