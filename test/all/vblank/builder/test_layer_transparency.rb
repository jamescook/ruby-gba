# frozen_string_literal: true

require "test_helper"
require "differential"
require "stringio"

# The see-through games and the colours they show, shared with the Advance cartridge's own
# tests of the same pictures (test/lowering/gba/vblank/builder/test_layer_transparency_cartridge.rb).
module LayerTransparencyGames
  include SharedConstants

  RED = VBlank::Graphics::Color.resolve(:red)
  WHITE = VBlank::Graphics::Color.resolve(:white)
  GREEN = VBlank::Graphics::Color.resolve(:green)

  # White over red, half way: each channel takes half of each side and the sixteenth is
  # dropped once, from the sum. Named rather than derived — it is the number the console
  # was measured to give, and deriving it would let a wrong rule move both sides.
  HALF_WHITE_OVER_RED = 0x3DFF

  SCENERY_XY = [8, 8].freeze
  SPRITE_XY = [66, 66].freeze

  # The console is drawing while it boots, and the tiles are uploaded before the blend is
  # set up, so the first frame is the layer solid — the same on a fixed amount as on one
  # the game works out. Measured, not chosen.
  CONSOLE_LAG = 2

  # The real shape of it: a hit flash, walked over frames by the effects pack, whose last
  # act is a fade of zero. This is the failure the bead describes — and the amount here is
  # one the game works out as it runs, which is the branch rather than the settled zero.
  FLASH_AT = 3
  AFTER_THE_FLASH = 20

  SWITCH_AT = 6 # frames of the first scene before the game hands over to the second

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A red floor with a white pane over it, the pane's layer see-through by +amount+.
  private def scenery_program(amount)
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
  private def sprite_program(amount)
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

  # A white pane over a red floor whose see-through amount walks from all the way
  # through (100) to solid (0), a step a frame.
  private def clearing_program(amount = nil)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:back, "#" => :red) { tile }
      image(:front, "#" => :white) { tile }
      tiles :backset, "#" => :back
      tiles :frontset, "#" => :front
      layers :deep, :glass
      layer(:deep) { background :floor, tiles: :backset, map: Array.new(20) { "#" * 30 } }
      clear = var :clear, 100
      layer(:glass, transparency: amount ? instance_exec(clear, &amount) : clear) do
        background :pane, tiles: :frontset, map: Array.new(20) { "#" * 20 }
      end
      game_loop { clear.approach! 0, 10 }
    end
  end

  # The same picture, with a fade held at a fixed amount. `hold` of 0 is a lifted fade.
  private def faded_program(kind, amount, hold, toward: :black)
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
        if kind == :scenery
          background :pane, tiles: :frontset, map: Array.new(20) { "#" * 20 }
        else
          sprite :front, at: [64, 64]
        end
      end
      game_loop { fade toward, hold }
    end
  end

  private def faded_xy(kind) = kind == :scenery ? SCENERY_XY : SPRITE_XY

  private def flashing_program(kind)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:back, "#" => :red) { tile }
      image(:front, "#" => :white) { tile }
      tiles :backset, "#" => :back
      tiles :frontset, "#" => :front
      layers :deep, :glass
      layer(:deep) { background :floor, tiles: :backset, map: Array.new(20) { "#" * 30 } }
      layer(:glass, transparency: 50) do
        if kind == :scenery
          background :pane, tiles: :frontset, map: Array.new(20) { "#" * 20 }
        else
          sprite :front, at: [64, 64]
        end
      end
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick == FLASH_AT).then { flash_screen :black, frames: 6 }
      end
    end
  end

  # THE TWO HALVES TOGETHER, which is where a hand-back could quietly be wrong: a fade
  # takes the blend, and the amount to give back is one the game has gone on working out
  # while the fade ran. Mist half thick when the flash ends comes back half thick — not at
  # the amount it started the game with.
  #
  # Said as "the flash left no trace": the picture afterwards is the picture the same game
  # draws with no flash in it at all.
  # The fade here is written by hand rather than walked by `flash_screen`, and that is the
  # point: it lands at the END of the frame's work, after the amount for this frame has
  # already been sent. So a hand-back that gave the amount the game STARTED with would
  # hold for the whole frame, and the next, and every one after it.
  private def thickening_program(lifting:)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:back, "#" => :red) { tile }
      image(:front, "#" => :white) { tile }
      tiles :backset, "#" => :back
      tiles :frontset, "#" => :front
      layers :deep, :glass
      layer(:deep) { background :floor, tiles: :backset, map: Array.new(20) { "#" * 30 } }
      clear = var :clear, 100
      layer(:glass, transparency: clear) do
        background :pane, tiles: :frontset, map: Array.new(20) { "#" * 20 }
      end
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        clear.approach! 0, 2
        (tick > FLASH_AT).then { fade :black, 0 } if lifting
      end
    end
  end

  # A banner scene that sees through nothing, handing over to a floor with a pane of glass
  # over it. The pane is the SIXTH thing in the program's list of scenery and the SECOND on
  # the hardware, which is the whole of what this is about.
  private def scenes_that_take_turns
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:back, "#" => :red) { tile }
      image(:front, "#" => :white) { tile }
      image(:other, "#" => :green) { tile }
      tiles :backset, "#" => :back
      tiles :frontset, "#" => :front
      tiles :otherset, "#" => :other
      full = Array.new(20) { "#" * 30 }
      layers :banner, :sky, :deep, :glass
      var :state, 0

      scene :title do
        layer(:banner) { background :banner, tiles: :otherset, map: full }
        layer(:sky) { background :sky, tiles: :otherset, map: full }
      end

      scene :play do
        layer(:deep) { background :floor, tiles: :backset, map: full }
        layer(:glass, transparency: 50) { background :pane, tiles: :frontset, map: full }
      end

      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick > SWITCH_AT).then { set! :state, 1 }
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
  end

  # A fade PLACED in the stack is still a fade — it takes the same blend unit, whatever it
  # leaves alone — so the rule and the hand-back have to reach it too.
  private def placed_fade_program(amount, hold)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:back, "#" => :red) { tile }
      image(:front, "#" => :white) { tile }
      image(:badge, "#" => :green) { tile }
      tiles :backset, "#" => :back
      tiles :frontset, "#" => :front
      layers :deep, :glass, :ui
      layer(:deep) { background :floor, tiles: :backset, map: Array.new(20) { "#" * 30 } }
      layer(:glass, transparency: amount) do
        background :pane, tiles: :frontset, map: Array.new(20) { "#" * 20 }
      end
      layer(:ui) { sprite :badge, at: [200, 8] }
      game_loop { fade :black, hold, under: :ui }
    end
  end

  private def shown(program, x, y, frames: 2)
    game_player.run(program, frames: frames).screen.pixel(x, y)
  end

  private def walked(program, frames) = (1..frames).map { |f| shown(program, *SCENERY_XY, frames: f) }

  # A TINT does not take the blend, and the warning above sends people here — so it is a
  # promise the suite has to keep. On a tiled screen a tint moves the colors themselves
  # rather than asking the display to blend, so the layer keeps seeing through them: a
  # `flash_screen :red` reaches a game the water can be seen through and a white one does
  # not. What shows is the layer blending TINTED colors, so it is neither the plain
  # see-through value nor the solid one.
  private def tinted_program(amount, hold)
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
        background :pane, tiles: :frontset, map: Array.new(20) { "#" * 20 }
      end
      game_loop { tint :blue, hold }
    end
  end
end

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
# The one thing a reader would not guess is that a see-through sprite never shows another
# sprite through it, only scenery; that has tests of its own, with the pictures, in
# test/console/gba/vblank/builder/test_layer_transparency_on_the_advance.rb.
#
# The pictures read back from the Advance's cartridge in the emulator, and what its build
# report says, are in test/lowering/gba/vblank/builder/test_layer_transparency_cartridge.rb.
class TestLayerTransparency < Minitest::Test
  include LayerTransparencyGames

  # --- an amount the game works out (fog that thickens) ---
  #
  # A number the author writes is sent to the display once at boot and never again. An
  # amount the GAME works out has to be sent again before every frame — so the same
  # keyword covers fog that thickens, water that gets murkier as you go down, a menu
  # backdrop that dims in. The author writes a variable where they wrote a number.

  # --- ...and what it costs, which is the reason it is not simply the same feature ---

  # A number the author wrote is sent once at boot: there is nothing per frame to make.
  def test_a_fixed_amount_makes_no_per_frame_work
    assert_empty scenery_program(40).walk.select { |n| n.kind == :see_through }
  end

  def test_an_amount_the_game_works_out_is_sent_every_frame
    assert_equal 1, clearing_program.walk.count { |n| n.kind == :see_through }
  end

  # An amount the game works out is not free, and the two tests above say exactly why: a
  # fixed one puts nothing in the frame, a worked-out one puts one write there. That is the
  # whole difference, and it is a fact about the tree rather than a claim about time.

  # The 100 warning cannot answer for a variable — passing through 100 for a frame is a
  # fog that cleared, not a layer nobody can see. Same silence `fade` and `tint` keep.
  def test_a_worked_out_amount_is_not_warned_about_at_100
    refute_includes warnings(clearing_program), :layer_invisible
  end

  # --- what it refuses ---

  def test_an_amount_outside_the_range_says_the_range
    error = assert_raises(ArgumentError) { scenery_program(140) }

    assert_includes error.message, "0 to 100"
  end

  def test_an_amount_that_is_neither_a_number_nor_a_value_says_both
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        layers :glass
        layer(:glass, transparency: "half") { nil }
      end
    end

    assert_includes error.message, "whole number"
    assert_includes error.message, "works out"
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

  # A SCREEN has one see-through layer, and the message names both. Two on different
  # screens are fine (see test_layer_two_amounts.rb); these two are on the same one.
  def test_a_second_see_through_layer_on_the_same_screen_is_refused
    tile = SOLID_TILE
    err = StringIO.new
    assert_raises(VBlank::ROMError) do
      VBlank.build("LAYERS", console: :gba, out: StringIO.new, err: err) do
        screen :tiled
        image(:art, "#" => :white) { tile }
        layers :water, :jellyfish
        layer(:water, transparency: 40) { sprite :art, at: [0, 0] }
        layer(:jellyfish, transparency: 40) { sprite :art, at: [8, 8] }
        game_loop { wait_vblank }
      end
    end

    assert_includes err.string, ":water"
    assert_includes err.string, ":jellyfish"
    assert_includes err.string, "one see-through layer"
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

  private def warnings(program)
    VBlank::IR::Guardrails::Validator.new.run(program, autofix: false).warnings.map(&:check)
  end

  def test_a_layer_nobody_can_see_is_a_warning
    assert_includes warnings(scenery_program(100)), :layer_invisible
  end

  def test_a_layer_you_can_partly_see_is_a_style_choice
    refute_includes warnings(scenery_program(60)), :layer_invisible
  end

  # The collision that is LEFT is worth saying out loud, because neither verb mentions
  # the other and the picture that shows it is over in half a second.
  def test_a_game_that_places_a_fade_over_a_see_through_layer_is_told
    finding = VBlank::IR::Guardrails::Validator.new
                                                .run(placed_fade_program(50, 25), autofix: false)
                                                .warnings
                                                .find { |w| w.check == :layer_solid_while_fading }

    assert finding, "a game that places a fade over a see-through layer was told nothing"
    assert_includes finding.message, ":glass"
    assert_includes finding.message, "solid"
    assert_includes finding.message, ":ui", "the message does not say which fade it is about"
  end

  # ...and the case it used to be about is gone, because the picture it described is gone.
  def test_a_whole_screen_fade_over_a_see_through_layer_is_not_warned_about
    refute_includes warnings(flashing_program(:scenery)), :layer_solid_while_fading
  end

  def test_a_see_through_layer_with_no_fade_is_not_warned_about
    refute_includes warnings(scenery_program(40)), :layer_solid_while_fading
  end

  def test_a_fade_with_no_see_through_layer_is_not_warned_about
    refute_includes warnings(faded_program(:scenery, 0, 50)), :layer_solid_while_fading
  end
end
