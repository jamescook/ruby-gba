# frozen_string_literal: true

require "test_helper"
require "differential"
require "stringio"

# THE TESTS OF ruby_gba/builder/test_layer_transparency.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
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
# sprite through it, only scenery; that has tests of its own below.
class TestLayerTransparencyOnTheAdvance < Minitest::Test
  include Differential

  RED = RubyGBA::Graphics::Color.resolve(:red)
  WHITE = RubyGBA::Graphics::Color.resolve(:white)
  GREEN = RubyGBA::Graphics::Color.resolve(:green)

  # White over red, half way: each channel takes half of each side and the sixteenth is
  # dropped once, from the sum. Named rather than derived — it is the number the console
  # was measured to give, and deriving it would let a wrong rule move both sides.
  HALF_WHITE_OVER_RED = 0x3DFF

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # The build report reads a finished cartridge, so a program under test has to be lowered
  # and carry the record the build made — where each routine ended up cannot be recovered
  # from the bytes afterwards.
  private def report_of(prog)
    backend = RubyGBA::IR::Backends::GBA.new
    machine_code = backend.lower(prog)
    rom = RubyGBA::Cartridge::ROM.assemble(machine_code, title: "LAYR", code: "LAYR", maker: "01",
                                              built: backend.build_record(prog))
    out = StringIO.new
    RubyGBA::Diagnostics::BuildReport.render(rom, out: out)
    out.string
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

  SCENERY_XY = [8, 8].freeze
  SPRITE_XY = [66, 66].freeze

  private def shown(program, x, y, frames: 2)
    game_player.run(program, frames: frames).screen.pixel(x, y)
  end

  private def console(program, x, y, name, frames: 6)
    assert_emulator_loads_rom(assemble_rom(program, name: name), frames: frames).pixel_gba(x, y)
  end

  # --- the picture ---

  # ONE SEE-THROUGH SPRITE IN A GAME THAT NAMES NO OTHER LAYER — a ghost, a shield bubble —
  # needs no verb of its own: a stack of one layer holding it is two lines, and nothing else
  # in the game has to name a layer, since what names none keeps the place it had. The layer
  # and a per-sprite word would reach the same bit of the sprite's table entry and share the
  # console's one amount, so a second spelling would only be a second way to ask.
  private def lone_ghost_program
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:back, "#" => :red) { tile }
      image(:ghost, "#" => :white) { tile }
      image(:hero, "#" => :green) { tile }
      tiles :backset, "#" => :back
      background :floor, tiles: :backset, map: Array.new(20) { "#" * 30 }
      sprite :hero, at: [24, 24]
      layers :ghosts
      layer(:ghosts, transparency: 50) { sprite :ghost, at: [64, 64] }
      game_loop { wait_vblank }
    end
  end

  # A SEE-THROUGH SPRITE SHOWS THE SCENERY UNDER IT, NEVER ANOTHER SPRITE. Of all the
  # sprites at a pixel the console draws the front one and no other, and only then mixes
  # it with the layer beneath, which is scenery or the backdrop. So a ghost passing over
  # the hero hides the hero where it covers them, and the floor shows through instead.
  #
  # A green hero, a white ghost over their corner, and a blue ghost over the white one's
  # corner. With +scrolling+ the floor is striped and moves a pixel a pass, which is the
  # other of the two ways the interpreter builds a picture — and stripes, so that scenery
  # kept a pixel out of place under a ghost is a different colour from the right one.
  private def ghost_over_hero_program(scrolling: false)
    tile = SOLID_TILE
    stripes = (["###....."] * 8).join("\n")
    program do
      screen :tiled
      image(:back, "#" => :red, "." => :yellow) { scrolling ? stripes : tile }
      image(:ghost, "#" => :white) { tile }
      image(:wisp, "#" => :blue) { tile }
      image(:hero, "#" => :green) { tile }
      tiles :backset, "#" => :back
      floor = background :floor, tiles: :backset, map: Array.new(32) { "#" * 32 }
      sprite :hero, at: [60, 60]
      layers :ghosts
      layer(:ghosts, transparency: 50) do
        sprite :ghost, at: [64, 64]
        sprite :wisp, at: [68, 68]
      end
      game_loop { floor.scroll_by 1, 0 if scrolling }
    end
  end

  HERO_ALONE = [61, 61].freeze
  GHOST_OVER_HERO = [65, 65].freeze
  WISP_OVER_GHOST = [69, 69].freeze

  # Blue over red, half way, as HALF_WHITE_OVER_RED is white over red: the number the
  # console was measured to give for this program, not one worked out.
  HALF_BLUE_OVER_RED = 0x3C0F

  # The same ghost over the same hero with a fence in the stack: a layer of scenery whose
  # tiles are blue bars with gaps between them. +stack+ says where the fence stands. In
  # front of both, the ghost shows through the gaps mixed with the floor. Between the two,
  # the ghost is mixed with a bar where there is one and with the floor through a gap, and
  # the hero behind the gap is still not seen.
  private def ghost_and_fence_program(stack)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:back, "#" => :red) { tile }
      image(:bars, "#" => :blue, "." => :transparent) { (["##..##.."] * 8).join("\n") }
      image(:ghost, "#" => :white) { tile }
      image(:hero, "#" => :green) { tile }
      tiles :backset, "#" => :back
      tiles :fenceset, "#" => :bars
      layers(*stack)
      layer(:deep) { background :floor, tiles: :backset, map: Array.new(20) { "#" * 30 } }
      layer(:fence) { background :fence, tiles: :fenceset, map: Array.new(20) { "#" * 30 } }
      layer(:actors) { sprite :hero, at: [60, 60] }
      layer(:ghosts, transparency: 50) { sprite :ghost, at: [64, 64] }
      game_loop { wait_vblank }
    end
  end

  # --- and the console agrees, which is the point of having two backends ---

  # --- an amount the game works out (fog that thickens) ---
  #
  # A number the author writes is sent to the display once at boot and never again. An
  # amount the GAME works out has to be sent again before every frame — so the same
  # keyword covers fog that thickens, water that gets murkier as you go down, a menu
  # backdrop that dims in. The author writes a variable where they wrote a number.

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

  private def walked(program, frames) = (1..frames).map { |f| shown(program, *SCENERY_XY, frames: f) }

  # The console is drawing while it boots, and the tiles are uploaded before the blend is
  # set up, so the first frame is the layer solid — the same on a fixed amount as on one
  # the game works out. Measured, not chosen.
  CONSOLE_LAG = 2

  # --- ...and what it costs, which is the reason it is not simply the same feature ---

  # An amount the game works out is not free, and the two tests above say exactly why: a
  # fixed one puts nothing in the frame, a worked-out one puts one write there. That is the
  # whole difference, and it is a fact about the tree rather than a claim about time.

  # --- a fade takes the blend, and hands it back ---
  #
  # Fading the screen and seeing through a layer are the display's ONE blend unit, told
  # which of the two it is doing. So while a fade runs the layer is solid and darkens with
  # everything else — which is what a fade out is supposed to look like — and it comes
  # back the moment the fade lifts. The bug this exists to remove is the second half: a
  # fade ends at ZERO, which is invisible but still a fade, so one hit flash used to turn
  # the water solid for the rest of the game with nothing anywhere to say why.

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

  # A FADE THE DISPLAY DOES, LEFT ON FROM A BITMAP SCREEN. A bitmap screen holds a whole
  # colour in every pixel, so a fade there is the display's own, and it stays until it is
  # lifted. The title is blue, faded half way to black; from the fifth pass a room takes
  # over, with mist over its floor and a walker in front of the mist. The display fades the
  # picture or sees through a layer, never both, so while the fade is on the mist is solid
  # and dark with everything else.
  #
  # +paints+ says how the title paints its blue: every pass, or on its first pass and then
  # left alone, which is how a title that draws nothing more is written. +room_at+ is the
  # pass the room takes over on. A block is what the room says on each of its passes, handed
  # the count of passes: lifting the fade on one of them, say.
  #
  # With +rooms+ the game has a second room drawn from tiles, a hall of two solid layers
  # with nothing seen through, and +rooms+ names the one the title hands over to. The other
  # is never gone to. What it changes is that the rooms want different things of the
  # display's blend, so each says its own on every pass it runs, not once for the game.
  private def faded_title_then_misty_room(paints: :every_pass, room_at: 4, rooms: nil, &says)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:dim_floor, "#" => rgb(20, 4, 30)) { tile }
      image(:dim_pane, "#" => rgb(16, 8, 2)) { tile }
      image(:walker, "#" => :red) { tile }
      tiles :floors, "d" => :dim_floor
      tiles :panes, "d" => :dim_pane
      where = var :where, 0
      pass = var :pass, 0
      rooms ? layers(:ground, :mist, :panelling, :walkers) : layers(:ground, :mist, :walkers)
      scene :title do
        screen :bitmap
        paints == :once ? (pass == 1).then { clear_screen :blue } : clear_screen(:blue)
        fade :black, 50
      end
      scene :room do
        layer(:ground) { background :floor, tiles: :floors, map: Array.new(20) { "d" * 30 } }
        layer(:mist, transparency: 50) { background :pane, tiles: :panes, map: Array.new(20) { "d" * 30 } }
        layer(:walkers) { sprite :walker, at: [40, 40] }.x.add! 1
        instance_exec(pass, &says) if says && rooms != :hall
      end
      if rooms
        scene :hall do
          layer(:ground) { background :hall_floor, tiles: :floors, map: Array.new(20) { "d" * 30 } }
          layer(:panelling) { background :hall_pane, tiles: :panes, map: Array.new(20) { "d" * 30 } }
          instance_exec(pass, &says) if says && rooms == :hall
        end
      end
      game_loop do
        pass.add! 1
        (pass == room_at).then { where.set!(rooms == :hall ? 2 : 1) }
        case_var(:where) do
          when_val 0, :title
          when_val 1, :room
          when_val 2, :hall if rooms
        end
      end
    end
  end

  private def rgb5(r, g, b) = r | (g << 5) | (b << 10)

  # Blue half way to black, and the pane's own colour half way to black: the mist drawn
  # solid under the fade. Blue lands on 15, not 16: the display's fade loses the fraction of
  # a channel kept above red (see Framebuffer#darkened_by_display).
  BLUE_FADED = [0, 0, 15].freeze
  SOLID_MIST_FADED = [8, 4, 1].freeze

  # Both backends agree on the game at each of +frames+, a fade or a see-through mix in force.
  private def assert_backends_agree_through_the_fade(game, frames)
    frames.each { |at| assert_backends_agree(game, frames: at, console_frames: at + 1) }
  end

  private def seen_through_mist = game_player.run(scene_mist_with_no_fade, frames: 8).screen.pixel(200, 100)

  # The same of a fade PLACED in the stack, which is the display's own on any screen: a tint
  # said after it takes its place, and the mist it had made solid is seen through again.
  private def placed_fade_then_a_tint
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:dim_floor, "#" => rgb(20, 4, 30)) { tile }
      image(:dim_pane, "#" => rgb(16, 8, 2)) { tile }
      tiles :floors, "d" => :dim_floor
      tiles :panes, "d" => :dim_pane
      pass = var :pass, 0
      layers :ground, :mist, :top
      layer(:ground) { background :floor, tiles: :floors, map: Array.new(20) { "d" * 30 } }
      layer(:mist, transparency: 50) { background :pane, tiles: :panes, map: Array.new(20) { "d" * 30 } }
      game_loop do
        pass.add! 1
        (pass == 3).then { fade :black, 50, under: :top }
        (pass == 6).then { tint :red, 0 }
      end
    end
  end

  def test_a_tint_takes_the_place_of_a_fade_placed_in_the_stack
    game = placed_fade_then_a_tint
    [2, 4, 5, 7, 8, 10].each { |frames| assert_backends_agree(game, frames: frames) }

    assert_equal rgb5(8, 4, 1), game_player.run(game, frames: 5).screen.pixel(200, 100), "solid and dark under the fade"
    assert_equal seen_through_mist, game_player.run(game, frames: 10).screen.pixel(200, 100), "seen through after the tint"
  end

  # The same room with no title and no fade: what the mist looks like seen through.
  private def scene_mist_with_no_fade
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:dim_floor, "#" => rgb(20, 4, 30)) { tile }
      image(:dim_pane, "#" => rgb(16, 8, 2)) { tile }
      tiles :floors, "d" => :dim_floor
      tiles :panes, "d" => :dim_pane
      layers :ground, :mist
      layer(:ground) { background :floor, tiles: :floors, map: Array.new(20) { "d" * 30 } }
      layer(:mist, transparency: 50) { background :pane, tiles: :panes, map: Array.new(20) { "d" * 30 } }
      game_loop { wait_vblank }
    end
  end

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

  # --- what it refuses ---

  # --- the guardrail ---

  private def warnings(program)
    RubyGBA::IR::Guardrails::Validator.new.run(program, autofix: false).warnings.map(&:check)
  end

  # --- a see-through layer in a game that has SCENES ---
  #
  # The display is told which layers to blend by NUMBER, and scenes take turns with the
  # console's layers — so the number a background sits on depends on which scene it was
  # declared in, and a scene that sees through nothing must have the blend off rather than
  # pointed at whatever background inherited that number.

  SWITCH_AT = 6 # frames of the first scene before the game hands over to the second

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

  # A PLAIN BITMAP TITLE AND A MISTY ROOM, in either order, with nothing faded until a block
  # says so. +first+ is the scene the game starts in and +swap_at+ the pass the other takes
  # over on; +title+ and +room+ are what each says on its passes, handed the count.
  #
  # A fade or a flash in this game walks the colors, since the mist is seen through. The
  # title has no colors to walk — it holds a whole color in every pixel — so there the
  # display does it, and whichever screen comes next takes it up its own way.
  private def title_and_misty_room(first:, swap_at:, title: nil, room: nil)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:dim_floor, "#" => rgb(20, 4, 30)) { tile }
      image(:dim_pane, "#" => rgb(16, 8, 2)) { tile }
      tiles :floors, "d" => :dim_floor
      tiles :panes, "d" => :dim_pane
      where = var :where, first == :title ? 0 : 1
      pass = var :pass, 0
      layers :ground, :mist
      scene :title do
        screen :bitmap
        clear_screen :blue
        instance_exec(pass, &title) if title
      end
      scene :room do
        layer(:ground) { background :floor, tiles: :floors, map: Array.new(20) { "d" * 30 } }
        layer(:mist, transparency: 50) { background :pane, tiles: :panes, map: Array.new(20) { "d" * 30 } }
        instance_exec(pass, &room) if room
      end
      game_loop do
        pass.add! 1
        (pass == swap_at).then { where.set!(first == :title ? 1 : 0) }
        case_var(:where) do
          when_val 0, :title
          when_val 1, :room
        end
      end
    end
  end

  # TWO ROOMS, EACH SEEING THROUGH A LAYER OF ITS OWN BY ITS OWN AMOUNT, taking turns. The
  # display holds one pair of amounts, so each room has to tell it its own as it takes over —
  # on that frame, not the one after, or the room's first frame is mixed by the other room's
  # amounts.
  #
  # With +walker+ the misty room has a sprite of its own walking in front of its mist. With
  # +title+ the game opens on a plain bitmap title and goes title, misty, foggy, misty.
  private def two_misty_rooms(walker: false, title: false)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:back, "#" => :red) { tile }
      image(:front, "#" => :white) { tile }
      image(:walker, "#" => :green) { tile }
      tiles :backset, "#" => :back
      tiles :frontset, "#" => :front
      full = Array.new(20) { "#" * 30 }
      layers :deep, :mist, :fog, :walkers
      where = var :where, title ? 2 : 0
      pass = var :pass, 0
      if title
        scene :title do
          screen :bitmap
          clear_screen :blue
        end
      end
      scene :misty do
        layer(:deep) { background :floor, tiles: :backset, map: full }
        layer(:mist, transparency: 50) { background :pane, tiles: :frontset, map: full }
        layer(:walkers) { sprite :walker, at: [40, 40] }.x.add! 1 if walker
      end
      scene :foggy do
        layer(:deep) { background :fog_floor, tiles: :backset, map: full }
        layer(:fog, transparency: 25) { background :fog_pane, tiles: :frontset, map: full }
      end
      game_loop do
        pass.add! 1
        (pass == 3).then { where.set! 0 } if title
        (pass == (title ? 6 : 4)).then { where.set! 1 }
        (pass == (title ? 9 : 8)).then { where.set! 0 }
        case_var(:where) do
          when_val 0, :misty
          when_val 1, :foggy
          when_val 2, :title if title
        end
      end
    end
  end

end
