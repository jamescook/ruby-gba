# frozen_string_literal: true

require "test_helper"
require "differential"

# A SEE-THROUGH LAYER GIVEN TWO AMOUNTS: how much of ITSELF shows, and how much of what is
# BEHIND it. `transparency:` splits one whole between the two; these need not add to one,
# and a sum past a whole comes out brighter than either side and stops at full brightness —
# which is how a window glows over a backdrop, or a shaft of light brightens a forest.
#
# The console mixes in sixteenths, so an amount is rounded to the nearest one: 94 is 15/16
# and 63 is 10/16, the pair a retail cartridge's file-select window is drawn with.
class TestLayerTwoAmounts < Minitest::Test
  include Differential

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # Two columns of floor under a pane: on the left a dim pane over a dim floor, where
  # nothing reaches full brightness; on the right white over red, where red and green
  # both run past it. +effect+ is a verb, a color and an amount said every frame.
  private def pane_program(shows:, behind:, effect: nil)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:dim_floor, "#" => rgb(20, 4, 30)) { tile }
      image(:red_floor, "#" => :red) { tile }
      image(:dim_pane, "#" => rgb(16, 8, 2)) { tile }
      image(:white_pane, "#" => :white) { tile }
      tiles :floors, "d" => :dim_floor, "r" => :red_floor
      tiles :panes, "d" => :dim_pane, "w" => :white_pane
      layers :deep, :glass
      layer(:deep) { background :floor, tiles: :floors, map: Array.new(20) { ("d" * 15) + ("r" * 15) } }
      layer(:glass, shows: shows, shows_behind: behind) do
        background :pane, tiles: :panes, map: Array.new(20) { ("d" * 15) + ("w" * 15) }
      end
      game_loop { effect ? public_send(*effect) : wait_vblank }
    end
  end

  private def rgb5(r, g, b) = r | (g << 5) | (b << 10)

  # Each channel is (pane x 15 + floor x 10) / 16, the sixteenth dropped once, worked in
  # eight bits the way the emulator mixes (16 is 132, 20 is 165, 31 is 255) and taken back
  # to five. Measured on the console, where the five-bit sum gives (27, 10, 20).
  DIM = [8, 8].freeze
  # (132*15 + 165*10) / 16 = 226 -> 28, (66*15 + 33*10) / 16 = 82 -> 10, (16*15 + 247*10) / 16 = 169 -> 21
  DIM_MIXED = [28, 10, 21].freeze
  BRIGHT = [200, 8].freeze
  # red: 255*25/16 is past full, so 31; green and blue: 255*15/16 = 239 -> 29
  BRIGHT_MIXED = [31, 29, 29].freeze

  # AMOUNTS THE GAME WORKS OUT, the way a retail title steps its light rays through
  # (9,9) (8,10) (7,11) sixteenths — the layer fading as what is behind comes up. Here the
  # step moves every frame, so the frame read decides the pair.
  private def stepping_program
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:dim_floor, "#" => rgb(20, 4, 30)) { tile }
      image(:dim_pane, "#" => rgb(16, 8, 2)) { tile }
      tiles :floors, "d" => :dim_floor
      tiles :panes, "d" => :dim_pane
      step = var :step, 0
      layers :deep, :glass
      layer(:deep) { background :floor, tiles: :floors, map: Array.new(20) { "d" * 30 } }
      # 9 and 9 sixteenths at step 0, then one sixteenth less of the pane and one more of
      # the floor each frame.
      layer(:glass, shows: 57 - (step * 6), shows_behind: 57 + (step * 6)) do
        background :pane, tiles: :panes, map: Array.new(20) { "d" * 30 }
      end
      game_loop { (step < 4).then { step.add! 1 } }
    end
  end

  # A WALKER IN FRONT OF MIST THAT THICKENS, on a picture where nothing scrolls. The mist's
  # amounts step every third frame while the walker moves a pixel every frame: the walker is
  # drawn on every one of those frames, the ones where the mist changed included.
  private def walker_in_front_of_thickening_mist
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:dim_floor, "#" => rgb(20, 4, 30)) { tile }
      image(:dim_pane, "#" => rgb(16, 8, 2)) { tile }
      image(:walker, "#" => :red) { tile }
      tiles :floors, "d" => :dim_floor
      tiles :panes, "d" => :dim_pane
      step = var :step, 0
      pass = var :pass, 0
      layers :ground, :mist, :walkers
      layer(:ground) { background :floor, tiles: :floors, map: Array.new(20) { "d" * 30 } }
      layer(:mist, shows: 57 - (step * 6), shows_behind: 57 + (step * 6)) do
        background :pane, tiles: :panes, map: Array.new(20) { "d" * 30 }
      end
      walker = layer(:walkers) { sprite :walker, at: [40, 40] }
      game_loop do
        pass.add! 1
        walker.x.add! 1
        ((pass % 3) == 0).then { step.add! 1 }
      end
    end
  end

  RED = VBlank::Graphics::Color.resolve(:red)

  # The same over a picture that STAYS: the glass's amounts never change and nothing
  # scrolls, so the scenery is painted once and a walker in front of it is drawn onto it,
  # the scenery put back behind it as it moves on. What is put back is a mix too, and the
  # tint has to reach both sides of it.
  private def walker_over_still_glass
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:dim_floor, "#" => rgb(20, 4, 30)) { tile }
      image(:dim_pane, "#" => rgb(16, 8, 2)) { tile }
      image(:walker, "#" => :red) { tile }
      tiles :floors, "d" => :dim_floor
      tiles :panes, "d" => :dim_pane
      layers :ground, :glass, :walkers
      layer(:ground) { background :floor, tiles: :floors, map: Array.new(20) { "d" * 30 } }
      layer(:glass, shows: 57, shows_behind: 57) { background :pane, tiles: :panes, map: Array.new(20) { "d" * 30 } }
      walker = layer(:walkers) { sprite :walker, at: [40, 40] }
      game_loop do
        walker.x.add! 2
        tint :white, 50
      end
    end
  end

  # A see-through SPRITE under a tint: it is mixed with the scenery behind it, and the
  # tint reaches both before the mix, as it does for a layer of scenery.
  private def ghost_under_a_tint
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:dim_floor, "#" => rgb(20, 4, 30)) { tile }
      image(:ghost, "#" => rgb(16, 8, 2)) { tile }
      tiles :floors, "d" => :dim_floor
      layers :deep, :spooks
      layer(:deep) { background :floor, tiles: :floors, map: Array.new(20) { "d" * 30 } }
      ghost = layer(:spooks, shows: 57, shows_behind: 57) { sprite :ghost, at: [64, 64] }
      game_loop do
        ghost.x.add! 1
        tint :white, 50
      end
    end
  end

  # ONE SEE-THROUGH LAYER PER SCREEN, NOT PER GAME. A title whose light rays the game
  # steps, and a file screen whose window sits over its backdrop at fixed amounts: each
  # scene has a see-through layer of its own, and the two are never on screen together.
  # A press of A moves from the title to the file screen, and a press of B back.
  private def two_screens_program
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:forest, "#" => rgb(20, 4, 30)) { tile }
      image(:ray, "#" => rgb(16, 8, 2)) { tile }
      image(:backdrop, "#" => :red) { tile }
      image(:window, "#" => :white) { tile }
      tiles :forests, "#" => :forest
      tiles :rays, "#" => :ray
      tiles :backdrops, "#" => :backdrop
      tiles :windows, "#" => :window
      full = Array.new(20) { "#" * 30 }
      layers :back, :rays, :window
      glow = var :glow, 0
      where = var :where, 0
      scene :title do
        layer(:back) { background :forest, tiles: :forests, map: full }
        layer(:rays, shows: 57 - glow, shows_behind: 57 + glow) { background :ray, tiles: :rays, map: full }
      end
      scene :files do
        layer(:back) { background :backdrop, tiles: :backdrops, map: full }
        layer(:window, shows: 94, shows_behind: 63) { background :window, tiles: :windows, map: full }
      end
      game_loop do
        pressed(:a).then { where.set! 1 }
        pressed(:b).then { where.set! 0 }
        glow.set! 6
        case_var(:where) do
          when_val 0, :title
          when_val 1, :files
        end
      end
    end
  end

  # (forest x 8 + ray x 10) / 16 in eight-bit channels: 165*8 + 132*8 ... worked out as
  # the title's rays at 51 and 63, which are 8 and 10 sixteenths.
  private def title_pixel = game_player.run(two_screens_program, frames: 4).screen.pixel(*DIM)

  private def files_pixel
    game_player.input_each_frame { |frame| frame == 1 ? [:a] : [] }
             .run(two_screens_program, frames: 6).screen.pixel(*DIM)
  end

  # Two see-through layers on ONE screen are refused: the console blends one layer with
  # what is behind it, so it cannot show both.
  def test_two_see_through_layers_on_one_screen_is_a_friendly_error
    tile = SOLID_TILE
    both = program do
      screen :tiled
      image(:a_tile, "#" => :red) { tile }
      image(:b_tile, "#" => :white) { tile }
      tiles :ones, "#" => :a_tile
      tiles :twos, "#" => :b_tile
      layers :mist, :glass
      layer(:mist, transparency: 40) { background :fog, tiles: :ones, map: ["#"] }
      scene :inside do
        layer(:glass, transparency: 60) { background :pane, tiles: :twos, map: ["#"] }
      end
      var :where, 0
      game_loop { case_var(:where) { when_val 0, :inside } }
    end
    checks = [VBlank::IR::Guardrails::Checks::SeeThroughPerScreen.new]
    message = VBlank::IR::Guardrails::Validator.new(checks: checks).run(both, autofix: false).errors.first.message

    assert_match(/:mist/, message)
    assert_match(/:glass/, message)
    assert_match(/:inside/, message, "it names the screen that shows both")
    error = assert_raises(Reference::ProgramError) { Reference.new.run(both) }
    assert_equal message, error.message
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(both) }
    assert_equal message, error.message
  end

  # --- friendly errors ---

  private def refused(**amounts)
    assert_raises(ArgumentError) do
      program do
        screen :tiled
        layers :glass
        layer(:glass, **amounts) { nil }
      end
    end
  end

  def test_one_amount_without_the_other_is_a_friendly_error
    error = refused(shows: 94)

    assert_match(/`shows:` but not `shows_behind:`/, error.message)
    assert_match(/give both/, error.message)
  end

  def test_two_amounts_beside_transparency_is_a_friendly_error
    assert_match(/two ways to say one thing/, refused(transparency: 40, shows: 94, shows_behind: 63).message)
  end

  def test_an_amount_past_100_is_a_friendly_error
    assert_match(/shows_behind: 120` is outside 0 to 100/, refused(shows: 50, shows_behind: 120).message)
  end

  # A layer whose own share rounds to nothing is drawn and cannot be seen — the warning
  # `transparency: 100` already gets.
  def test_showing_too_little_of_itself_to_see_is_a_friendly_warning
    err = StringIO.new
    VBlank.build("FAINT", console: :gba, out: StringIO.new, err: err) do
      screen :tiled
      image(:pane, "#" => :white) { "########\n" * 8 }
      tiles :panes, "#" => :pane
      layers :glass
      layer(:glass, shows: 2, shows_behind: 100) { background :pane, tiles: :panes, map: ["#"] }
      game_loop { wait_vblank }
    end

    assert_match(/shows 2 of itself\. That rounds to nothing/, err.string)
  end

end
