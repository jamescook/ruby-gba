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

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # Two columns of floor under a pane: on the left a dim pane over a dim floor, where
  # nothing reaches full brightness; on the right white over red, where red and green
  # both run past it.
  def pane_program(shows:, behind:)
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
      game_loop { wait_vblank }
    end
  end

  def rgb5(r, g, b) = r | (g << 5) | (b << 10)

  # Each channel is (pane x 15 + floor x 10) / 16, the sixteenth dropped once, worked in
  # eight bits the way the emulator mixes (16 is 132, 20 is 165, 31 is 255) and taken back
  # to five. Measured on the console, where the five-bit sum gives (27, 10, 20).
  DIM = [8, 8].freeze
  # (132*15 + 165*10) / 16 = 226 -> 28, (66*15 + 33*10) / 16 = 82 -> 10, (16*15 + 247*10) / 16 = 169 -> 21
  DIM_MIXED = [28, 10, 21].freeze
  BRIGHT = [200, 8].freeze
  # red: 255*25/16 is past full, so 31; green and blue: 255*15/16 = 239 -> 29
  BRIGHT_MIXED = [31, 29, 29].freeze

  def test_a_layer_can_show_itself_and_what_is_behind_by_amounts_of_their_own
    screen = Reference.new.run(pane_program(shows: 94, behind: 63), frames: 2).screen

    assert_equal rgb5(*DIM_MIXED), screen.pixel(*DIM)
    assert_equal rgb5(*BRIGHT_MIXED), screen.pixel(*BRIGHT), "past a whole, a channel stops at full"
  end

  # AMOUNTS THE GAME WORKS OUT, the way a retail title steps its light rays through
  # (9,9) (8,10) (7,11) sixteenths — the layer fading as what is behind comes up. Here the
  # step moves every frame, so the frame read decides the pair.
  def stepping_program
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

  def test_amounts_the_game_works_out_follow_it
    oracle_frames = (2..6).map { |frames| Reference.new.run(stepping_program, frames: frames).screen.pixel(*DIM) }

    assert_operator oracle_frames.uniq.size, :>, 1, "the mix changes as the step moves"
  end

  def test_the_console_follows_worked_out_amounts_too
    (2..6).each { |frames| assert_backends_agree(stepping_program, frames: frames) }
  end

  # A layer of SPRITES takes the same two amounts: the console blends each sprite in the
  # layer through its own table entry rather than naming a layer, and the shares are the
  # same register.
  def test_a_layer_of_sprites_takes_two_amounts
    tile = SOLID_TILE
    sprites = program do
      screen :tiled
      image(:red_floor, "#" => :red) { tile }
      image(:ghost, "#" => :white) { tile }
      tiles :floors, "r" => :red_floor
      layers :deep, :spooks
      layer(:deep) { background :floor, tiles: :floors, map: Array.new(20) { "r" * 30 } }
      layer(:spooks, shows: 94, shows_behind: 63) { sprite :ghost, at: [64, 64] }
      game_loop { wait_vblank }
    end
    oracle, console, = backend_pictures(sprites, frames: 2)

    assert_equal rgb5(*BRIGHT_MIXED), console[(66 * 240) + 66]
    assert_empty mismatched_pixels(oracle, console)
  end

  # ONE SEE-THROUGH LAYER PER SCREEN, NOT PER GAME. A title whose light rays the game
  # steps, and a file screen whose window sits over its backdrop at fixed amounts: each
  # scene has a see-through layer of its own, and the two are never on screen together.
  # A press of A moves from the title to the file screen, and a press of B back.
  def two_screens_program
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
  def title_pixel = Reference.new.run(two_screens_program, frames: 4).screen.pixel(*DIM)

  def files_pixel
    Reference.new.input_each_frame { |frame| frame == 1 ? [:a] : [] }
             .run(two_screens_program, frames: 6).screen.pixel(*DIM)
  end

  def test_two_scenes_can_each_have_a_see_through_layer
    assert_equal rgb5(*BRIGHT_MIXED), files_pixel, "the file screen's window at 15 and 10 over red"
    refute_equal title_pixel, files_pixel
  end

  def test_the_console_gives_each_screen_its_own_mix
    keys = ->(frame) { frame.between?(3, 4) ? RubyGBA::Console::Hardware::KEY_A : 0 }
    oracle, console, = backend_pictures(two_screens_program, frames: 2)
    assert_empty mismatched_pixels(oracle, console), "the title"

    v = assert_emulator_loads_rom(assemble_rom(two_screens_program, name: "SCREENS"), frames: 12, keys: keys)
    assert_equal rgb5(*BRIGHT_MIXED), v.pixel_gba(*DIM), "the file screen's window"

    v.step(2, keys: RubyGBA::Console::Hardware::KEY_B)
    v.step(4)
    assert_equal title_pixel, v.pixel_gba(*DIM), "back on the title, the rays' own mix"
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
    checks = [RubyGBA::IR::Guardrails::Checks::SeeThroughPerScreen.new]
    message = RubyGBA::IR::Guardrails::Validator.new(checks: checks).run(both, autofix: false).errors.first.message

    assert_match(/:mist/, message)
    assert_match(/:glass/, message)
    assert_match(/:inside/, message, "it names the screen that shows both")
    error = assert_raises(Reference::ProgramError) { Reference.new.run(both) }
    assert_equal message, error.message
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(both) }
    assert_equal message, error.message
  end

  # --- friendly errors ---

  def refused(**amounts)
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
    RubyGBA.build("FAINT", out: StringIO.new, err: err) do
      screen :tiled
      image(:pane, "#" => :white) { "########\n" * 8 }
      tiles :panes, "#" => :pane
      layers :glass
      layer(:glass, shows: 2, shows_behind: 100) { background :pane, tiles: :panes, map: ["#"] }
      game_loop { wait_vblank }
    end

    assert_match(/shows 2 of itself\. That rounds to nothing/, err.string)
  end

  def test_the_console_mixes_them_the_same_way
    oracle, console, = backend_pictures(pane_program(shows: 94, behind: 63), frames: 2)

    assert_equal rgb5(*DIM_MIXED), console[(DIM[1] * 240) + DIM[0]]
    assert_equal rgb5(*BRIGHT_MIXED), console[(BRIGHT[1] * 240) + BRIGHT[0]]
    assert_empty mismatched_pixels(oracle, console)
  end
end
