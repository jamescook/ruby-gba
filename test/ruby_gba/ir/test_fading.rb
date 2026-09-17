# frozen_string_literal: true

require "test_helper"

# WHICH PART OF THE DISPLAY A FADE TO BLACK OR WHITE USES.
#
# There are two ways to darken a whole picture on this console and a game gets one of
# them, decided here rather than in either backend, so the ROM and the headless
# interpreter cannot drift apart about it. What the two LOOK like is asserted where the
# picture is — `test/ruby_gba/builder/test_layer_transparency.rb`. This file is the
# rule: three decisions, one test each, in the words somebody would ask them in.
class TestFading < Minitest::Test

  TILE = (("#" * 8) + "\n").freeze * 8

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  def fading(prog) = RubyGBA::IR::Fading.resolve(prog)

  def fades(prog) = prog.walk.select { |node| node.kind == :fade }

  # A red floor with a white pane over it, the pane's layer half see-through, and a fade
  # written either over the whole screen or placed under the badge on top.
  def see_through_program(under: nil, transparency: 50)
    tile = TILE
    program do
      screen :tiled
      image(:back, "#" => :red) { tile }
      image(:front, "#" => :white) { tile }
      image(:badge, "#" => :green) { tile }
      tiles :backset, "#" => :back
      tiles :frontset, "#" => :front
      layers :deep, :glass, :ui
      layer(:deep) { background :floor, tiles: :backset, map: Array.new(20) { "#" * 30 } }
      # :worked_out asks for an amount the game computes, which is the case nothing at
      # build time can settle — a variable, the way fog that thickens is written.
      amount = transparency == :worked_out ? var(:mist, 100) : transparency
      layer(:glass, transparency: amount) do
        background :pane, tiles: :frontset, map: Array.new(20) { "#" * 20 }
      end
      layer(:ui) { sprite :badge, at: [200, 8] }
      game_loop { under ? fade(:black, 60, under: under) : fade(:black, 60) }
    end
  end

  # The same tiled game with nothing see-through in it at all.
  def plain_tiled_program
    tile = TILE
    program do
      screen :tiled
      image(:back, "#" => :red) { tile }
      tiles :backset, "#" => :back
      background :floor, tiles: :backset, map: Array.new(20) { "#" * 30 }
      game_loop { fade :black, 60 }
    end
  end

  def bitmap_program(tear_free:)
    program do
      screen :bitmap, tear_free: tear_free
      clear_screen :red
      game_loop { fade :black, 60 }
    end
  end

  # DECISION ONE: a fade walks the colours exactly when there is a layer to keep.
  #
  # Walking them is not free — it is a blend per colour the game declared, on each frame
  # the fade moves — where the display's own blend is free however much is on screen. So
  # a game that has nothing to see through keeps the free one, and the picture it draws
  # is the same either way, so nothing about that choice reaches the author.
  def test_a_fade_walks_the_colours_when_there_is_a_see_through_layer_to_keep
    prog = see_through_program

    assert fading(prog).walks_the_colors?(fades(prog).first)
  end

  def test_a_fade_keeps_the_free_blend_when_there_is_nothing_to_see_through
    prog = plain_tiled_program

    refute fading(prog).walks_the_colors?(fades(prog).first)
  end

  def test_a_game_with_nothing_to_see_through_has_no_colours_to_walk_at_all
    refute_predicate fading(plain_tiled_program), :any_color_walk?
  end

  # A layer DECLARED see-through and then fixed at nothing is solid, so there is nothing
  # behind it to keep and walking the colours would buy a picture nobody can tell from the
  # free fade. Worth its own test because the declaration is what a reader notices, and
  # naming the layer is the easy thing to key the whole decision off.
  def test_a_layer_that_is_see_through_by_nothing_does_not_buy_the_walk
    prog = see_through_program(transparency: 0)

    refute fading(prog).walks_the_colors?(fades(prog).first)
  end

  # ...and an amount the game works out DOES buy it, because nothing at build time knows
  # what it will be and it is not 0 for long if it was worth writing.
  def test_a_layer_as_see_through_as_the_game_works_out_buys_the_walk
    prog = see_through_program(transparency: :worked_out)

    assert fading(prog).walks_the_colors?(fades(prog).first)
  end

  # DECISION TWO: neither bitmap screen changes.
  #
  # Seeing through a layer needs a tiled screen, so a bitmap screen never has anything
  # for a fade to protect. The tear-free one is the one worth asserting: it DOES draw
  # through a colour table, so it is the screen somebody would expect to change, and it
  # does not.
  def test_a_plain_bitmap_screen_fades_the_way_it_always_did
    prog = bitmap_program(tear_free: false)

    refute fading(prog).walks_the_colors?(fades(prog).first)
  end

  def test_a_tear_free_bitmap_screen_fades_the_way_it_always_did_too
    prog = bitmap_program(tear_free: true)

    refute fading(prog).walks_the_colors?(fades(prog).first)
  end

  # DECISION THREE: a fade placed in the stack keeps the display's blend.
  #
  # Being placed is the one thing only the blend unit can do — the console hides a
  # brightness change from the layers in front of a line, where a table of colours is
  # read by everything that draws and has no notion of who is reading it. So this fade
  # still trades the layer away, which is what the guardrail is left warning about.
  def test_a_fade_placed_in_the_stack_keeps_the_blend
    placed = see_through_program(under: :ui)

    refute fading(placed).walks_the_colors?(fades(placed).first)
  end

  def test_a_placed_fade_is_the_one_the_game_is_warned_about
    placed = see_through_program(under: :ui)

    assert_equal fades(placed), fading(placed).blend_fades
  end

  def test_a_whole_screen_fade_leaves_nothing_to_warn_about
    assert_empty fading(see_through_program).blend_fades
  end
end
