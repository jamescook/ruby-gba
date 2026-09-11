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

  # The build report reads a finished cartridge, so a program under test has to be lowered
  # and carry the record the build made — where each routine ended up cannot be recovered
  # from the bytes afterwards.
  def report_of(prog)
    backend = RubyGBA::IR::Backends::GBA.new
    machine_code = backend.lower(prog)
    rom = RubyGBA::ROM.assemble(machine_code, title: "LAYR", code: "LAYR", maker: "01",
                                              built: backend.build_record(prog))
    out = StringIO.new
    RubyGBA::BuildReport.render(rom, out: out)
    out.string
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

  def shown(program, x, y, frames: 2)
    Reference.new.run(program, frames: frames).screen.pixel(x, y)
  end

  def console(program, x, y, name, frames: 6)
    assert_emulator_loads_rom(assemble_rom(program, name: name), frames: frames).pixel_gba(x, y)
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
                 assert_emulator_loads_rom(assemble_rom(program, name: "SEEHLD"), frames: 40).pixel_gba(*SPRITE_XY)
  end

  # --- an amount the game works out (fog that thickens) ---
  #
  # A number the author writes is sent to the display once at boot and never again. An
  # amount the GAME works out has to be sent again before every frame — so the same
  # keyword covers fog that thickens, water that gets murkier as you go down, a menu
  # backdrop that dims in. The author writes a variable where they wrote a number.

  # A white pane over a red floor whose see-through amount walks from all the way
  # through (100) to solid (0), a step a frame.
  def clearing_program(amount = nil)
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
      game_loop { clear.approach 0, 10 }
    end
  end

  def walked(program, frames) = (1..frames).map { |f| shown(program, *SCENERY_XY, frames: f) }

  # It starts at the floor (nothing of the pane shows) and ends at the pane (none of the
  # floor does), and every frame between is a different mix — which is the whole claim:
  # the amount is being re-read rather than settled once.
  def test_the_layer_thickens_as_the_game_works_it_out
    seen = walked(clearing_program, 11)

    assert_equal RED, seen.first, "it did not start see-through"
    assert_equal WHITE, seen.last, "it never became solid"
    assert_equal seen.uniq, seen, "the amount was not re-read every frame"
  end

  # ...and the console draws the same walk. Compared to the interpreter's own frames
  # rather than to written-down colors, so this cannot pass by agreeing with a table.
  def test_the_console_walks_the_same_amounts
    rom = assemble_rom(clearing_program, name: "FOG")
    oracle = walked(clearing_program, 10)
    seen = (1..10).map { |f| assert_emulator_loads_rom(rom, frames: f + CONSOLE_LAG).pixel_gba(*SCENERY_XY) }

    assert_equal oracle, seen
  end

  # The console is drawing while it boots, and the tiles are uploaded before the blend is
  # set up, so the first frame is the layer solid — the same on a fixed amount as on one
  # the game works out. Measured, not chosen.
  CONSOLE_LAG = 2

  # BEFORE the first frame boundary has even run, the layer is already at the amount its
  # variable starts at — boot writes that rather than waiting to be told. A game whose fog
  # starts clear must not flash solid on the way in.
  def test_the_first_frame_shows_the_amount_the_game_starts_at
    rom = assemble_rom(clearing_program, name: "FOGBOO")

    assert_equal RED, assert_emulator_loads_rom(rom, frames: CONSOLE_LAG).pixel_gba(*SCENERY_XY)
  end

  # An amount is a VALUE, not only a variable — so it can be worked out from the game's
  # own state on the spot. `100 - mist` is what an example actually writes.
  def test_the_amount_can_be_worked_out_on_the_spot
    from_a_sum = clearing_program(->(clear) { 100 - (100 - clear) })

    assert_equal walked(clearing_program, 8), walked(from_a_sum, 8)
  end

  def test_the_two_backends_draw_the_same_thickening_screen
    assert_backends_agree(clearing_program, frames: 6, console_frames: 6 + CONSOLE_LAG)
  end

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

  # --- a fade takes the blend, and hands it back ---
  #
  # Fading the screen and seeing through a layer are the display's ONE blend unit, told
  # which of the two it is doing. So while a fade runs the layer is solid and darkens with
  # everything else — which is what a fade out is supposed to look like — and it comes
  # back the moment the fade lifts. The bug this exists to remove is the second half: a
  # fade ends at ZERO, which is invisible but still a fade, so one hit flash used to turn
  # the water solid for the rest of the game with nothing anywhere to say why.

  # The same picture, with a fade held at a fixed amount. `hold` of 0 is a lifted fade.
  def faded_program(kind, amount, hold)
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
      game_loop { fade :black, hold }
    end
  end

  def faded_xy(kind) = kind == :scenery ? SCENERY_XY : SPRITE_XY

  # A see-through layer under a fade shows exactly what a SOLID layer under the same fade
  # shows. Said that way round on purpose: it needs no number of its own, so it cannot be
  # satisfied by a wrong blend that happens to match a constant written beside it.
  def test_while_a_fade_runs_the_layer_is_solid
    %i[scenery sprite].each do |kind|
      solid = shown(faded_program(kind, 0, 25), *faded_xy(kind))

      assert_equal solid, shown(faded_program(kind, 50, 25), *faded_xy(kind)),
                   "the see-through #{kind} layer is not solid while a fade runs"
    end
  end

  def test_the_console_makes_the_layer_solid_while_a_fade_runs_too
    %i[scenery sprite].each do |kind|
      solid = console(faded_program(kind, 0, 25), *faded_xy(kind), "FADSOL")

      assert_equal solid, console(faded_program(kind, 50, 25), *faded_xy(kind), "FADSEE"),
                   "the console leaves the see-through #{kind} layer blending under a fade"
    end
  end

  # ...and a fade of nothing is a lifted fade, not a fade of zero left in force.
  def test_a_lifted_fade_leaves_the_layer_see_through
    %i[scenery sprite].each do |kind|
      assert_equal HALF_WHITE_OVER_RED, shown(faded_program(kind, 50, 0), *faded_xy(kind))
      assert_equal HALF_WHITE_OVER_RED, console(faded_program(kind, 50, 0), *faded_xy(kind), "FADOFF")
    end
  end

  # A TINT does not take the blend, and the warning above sends people here — so it is a
  # promise the suite has to keep. On a tiled screen a tint moves the colors themselves
  # rather than asking the display to blend, so the layer keeps seeing through them: a
  # `flash_screen :red` reaches a game the water can be seen through and a white one does
  # not. What shows is the layer blending TINTED colors, so it is neither the plain
  # see-through value nor the solid one.
  def tinted_program(amount, hold)
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

  def test_a_tint_leaves_the_layer_see_through
    solid = shown(tinted_program(0, 50), *SCENERY_XY)

    refute_equal solid, shown(tinted_program(50, 50), *SCENERY_XY),
                 "a tint took the layer's blend away"
    assert_equal shown(tinted_program(50, 50), *SCENERY_XY),
                 console(tinted_program(50, 50), *SCENERY_XY, "TNTSEE"),
                 "the two backends disagree about a tint over a see-through layer"
  end

  # A fade PLACED in the stack is still a fade — it takes the same blend unit, whatever it
  # leaves alone — so the rule and the hand-back have to reach it too.
  def placed_fade_program(amount, hold)
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

  def test_a_fade_placed_in_the_stack_takes_the_blend_and_gives_it_back_too
    solid = shown(placed_fade_program(0, 25), *SCENERY_XY)

    assert_equal solid, shown(placed_fade_program(50, 25), *SCENERY_XY),
                 "a placed fade left the layer blending"
    assert_equal HALF_WHITE_OVER_RED, shown(placed_fade_program(50, 0), *SCENERY_XY)

    on_console = console(placed_fade_program(0, 25), *SCENERY_XY, "FADPLC")

    assert_equal on_console, console(placed_fade_program(50, 25), *SCENERY_XY, "FADPL2")
    assert_equal HALF_WHITE_OVER_RED, console(placed_fade_program(50, 0), *SCENERY_XY, "FADPL3")
  end

  # The real shape of it: a hit flash, walked over frames by the effects pack, whose last
  # act is a fade of zero. This is the failure the bead describes — and the amount here is
  # one the game works out as it runs, which is the branch rather than the settled zero.
  FLASH_AT = 3
  AFTER_THE_FLASH = 20

  def flashing_program(kind)
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
        tick.add 1
        (tick == FLASH_AT).then { flash_screen :black, frames: 6 }
      end
    end
  end

  def test_one_flash_does_not_cost_the_layer_for_the_rest_of_the_game
    %i[scenery sprite].each do |kind|
      screen = Reference.new.run(flashing_program(kind), frames: AFTER_THE_FLASH).screen

      assert_equal HALF_WHITE_OVER_RED, screen.pixel(*faded_xy(kind)),
                   "the #{kind} layer never came back after the flash"
    end
  end

  def test_the_console_gives_the_layer_back_after_a_flash_too
    %i[scenery sprite].each do |kind|
      assert_equal HALF_WHITE_OVER_RED,
                   console(flashing_program(kind), *faded_xy(kind), "FLSBAK", frames: AFTER_THE_FLASH),
                   "the console never gave the #{kind} layer back"
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
  def thickening_program(lifting:)
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
        tick.add 1
        clear.approach 0, 2
        (tick > FLASH_AT).then { fade :black, 0 } if lifting
      end
    end
  end

  def test_a_lifting_fade_hands_back_the_amount_the_game_has_now
    settled = AFTER_THE_FLASH + CONSOLE_LAG

    assert_equal console(thickening_program(lifting: false), *SCENERY_XY, "NOFADE", frames: settled),
                 console(thickening_program(lifting: true), *SCENERY_XY, "FOGFAD", frames: settled),
                 "the lifted fade left the layer at some other amount than the one the game had"
  end

  # The whole screen, once the flash is over and both backends have settled.
  def test_the_two_backends_draw_the_same_screen_after_a_fade
    assert_backends_agree(flashing_program(:scenery), frames: AFTER_THE_FLASH)
    assert_backends_agree(flashing_program(:sprite), frames: AFTER_THE_FLASH)
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

  # The collision is worth saying out loud, because neither verb mentions the other and
  # the picture that shows it is over in half a second.
  def test_a_game_that_fades_and_sees_through_a_layer_is_told
    finding = RubyGBA::IR::Guardrails::Validator.new
                                                .run(flashing_program(:scenery), autofix: false)
                                                .warnings
                                                .find { |w| w.check == :layer_solid_while_fading }

    assert finding, "a game that fades over a see-through layer was told nothing"
    assert_includes finding.message, ":glass"
    assert_includes finding.message, "solid"
  end

  def test_a_see_through_layer_with_no_fade_is_not_warned_about
    refute_includes warnings(scenery_program(40)), :layer_solid_while_fading
  end

  def test_a_fade_with_no_see_through_layer_is_not_warned_about
    refute_includes warnings(faded_program(:scenery, 0, 50)), :layer_solid_while_fading
  end

  def test_the_report_says_a_fade_takes_the_blend
    assert_includes report_of(flashing_program(:scenery)), "while a fade runs"
  end

  def test_the_report_leaves_that_out_when_nothing_fades
    refute_includes report_of(scenery_program(40)), "while a fade runs"
  end

  def test_the_report_says_which_layer_is_see_through
    assert_includes report_of(scenery_program(40)), ":glass is 40 see-through"
  end

  # ...and says that it costs nothing, which is the whole bargain of the tiled screen: the
  # display blends as it draws, so a see-through layer costs the same as the same layer drawn
  # solid, however much is on screen.
  def test_the_report_says_seeing_through_a_layer_is_free
    assert_includes report_of(scenery_program(40)), "the display blends it as it draws, for nothing"
  end
end
