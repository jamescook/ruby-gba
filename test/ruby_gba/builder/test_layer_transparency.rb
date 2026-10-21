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
# The one thing a reader would not guess is that a see-through sprite never shows another
# sprite through it, only scenery; that has tests of its own below.
class TestLayerTransparency < Minitest::Test
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
    screen = game_player.run(sprite_program(50), frames: 2).screen

    assert_equal HALF_WHITE_OVER_RED, screen.pixel(*SPRITE_XY), "the sprite blends"
    assert_equal RED, screen.pixel(*SCENERY_XY), "the floor beside it does not"
  end

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

  def test_one_see_through_sprite_needs_only_a_layer_of_its_own
    screen = game_player.run(lone_ghost_program, frames: 2).screen

    assert_equal HALF_WHITE_OVER_RED, screen.pixel(*SPRITE_XY), "the ghost blends"
    assert_equal GREEN, screen.pixel(26, 26), "the sprite that named no layer does not"
    assert_equal RED, screen.pixel(*SCENERY_XY), "nor the floor"
    assert_backends_agree(lone_ghost_program, frames: 2)
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

  def test_a_see_through_sprite_over_another_sprite_shows_the_scenery_and_not_the_sprite
    screen = game_player.run(ghost_over_hero_program, frames: 3).screen

    assert_equal GREEN, screen.pixel(*HERO_ALONE), "the hero, where nothing covers them"
    assert_equal HALF_WHITE_OVER_RED, screen.pixel(*GHOST_OVER_HERO), "the ghost hides the hero it covers"
    assert_equal HALF_BLUE_OVER_RED, screen.pixel(*WISP_OVER_GHOST), "and the wisp hides the ghost it covers"
  end

  def test_both_backends_draw_a_see_through_sprite_over_another_sprite_the_same
    assert_backends_agree(ghost_over_hero_program, frames: 2)
    [3, 6, 11].each { |frames| assert_backends_agree(ghost_over_hero_program(scrolling: true), frames: frames) }
  end

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

  def test_both_backends_draw_it_the_same_with_scenery_in_front_of_or_between_the_two
    assert_backends_agree(ghost_and_fence_program(%i[deep actors ghosts fence]), frames: 2)
    assert_backends_agree(ghost_and_fence_program(%i[deep actors fence ghosts]), frames: 2)
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
  #
  # The first frame SHOWN, which is not a fixed number: the picture is held off, white, until
  # the game's first frame is set up, and how long setting up takes is the game's own affair.
  def test_the_first_frame_shows_the_amount_the_game_starts_at
    rom = assemble_rom(clearing_program, name: "FOGBOO")
    v = assert_emulator_loads_rom(rom, frames: 1)
    # A few frames at most: a layer that came up solid is white too, and would never stop.
    CONSOLE_LAG.times { v.step if v.pixel_gba(*SCENERY_XY) == WHITE }

    assert_equal RED, v.pixel_gba(*SCENERY_XY)
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

  # A see-through layer under a fade does NOT show what a SOLID layer under the same fade
  # shows. Said that way round on purpose: it needs no number of its own, so it cannot be
  # satisfied by a wrong blend that happens to match a constant written beside it.
  def test_a_fade_leaves_the_layer_see_through
    %i[scenery sprite].each do |kind|
      solid = shown(faded_program(kind, 0, 25), *faded_xy(kind))

      refute_equal solid, shown(faded_program(kind, 50, 25), *faded_xy(kind)),
                   "the see-through #{kind} layer went solid while a fade ran"
    end
  end

  def test_the_console_leaves_the_layer_see_through_under_a_fade_too
    %i[scenery sprite].each do |kind|
      solid = console(faded_program(kind, 0, 25), *faded_xy(kind), "FADSOL")

      refute_equal solid, console(faded_program(kind, 50, 25), *faded_xy(kind), "FADSEE"),
                   "the console made the see-through #{kind} layer solid under a fade"
    end
  end

  # ...and both backends land on the SAME faded mix, which is the assertion that can
  # catch a blend done in the wrong order. Darkening each color and then mixing them is
  # not quite darkening the mix — the two truncate in different places — so this would
  # fail by a step if either side moved its colors at the wrong moment.
  def test_the_two_backends_agree_on_a_see_through_layer_under_a_fade
    %i[scenery sprite].each do |kind|
      assert_equal shown(faded_program(kind, 50, 25), *faded_xy(kind)),
                   console(faded_program(kind, 50, 25), *faded_xy(kind), "FADMIX"),
                   "the backends disagree about the #{kind} layer under a fade"
    end
  end

  # FADING TO WHITE IS THE OTHER DIRECTION AND NOT A MIRROR OF THE FIRST. Toward white a
  # channel adds a share of the headroom it has left; toward black it keeps a share of
  # what it has, and the two truncate opposite ways — so one direction can be right while
  # the other is a step out at every pixel. Both halves of the picture are asserted: the
  # layer is still blending, and the two backends land on the same color.
  def test_a_fade_to_white_leaves_the_layer_see_through_too
    solid = shown(faded_program(:scenery, 0, 25, toward: :white), *SCENERY_XY)

    refute_equal solid, shown(faded_program(:scenery, 50, 25, toward: :white), *SCENERY_XY),
                 "the see-through layer went solid while a fade to white ran"
  end

  def test_the_console_agrees_about_a_fade_to_white
    assert_equal shown(faded_program(:scenery, 50, 25, toward: :white), *SCENERY_XY),
                 console(faded_program(:scenery, 50, 25, toward: :white), *SCENERY_XY, "FADWHT")
  end

  # ...and a fade of nothing is a lifted fade, not a fade of zero left in force.
  def test_a_lifted_fade_leaves_the_layer_see_through
    %i[scenery sprite].each do |kind|
      assert_equal HALF_WHITE_OVER_RED, shown(faded_program(kind, 50, 0), *faded_xy(kind))
      assert_equal HALF_WHITE_OVER_RED, console(faded_program(kind, 50, 0), *faded_xy(kind), "FADOFF")
    end
  end

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

  # A picture painted once is still there under the fade on the frames after. A bitmap
  # screen has no scenery to build a picture from again, so nothing may ask it to.
  def test_a_fade_leaves_a_picture_painted_once_on_a_bitmap_screen
    title = faded_title_then_misty_room(paints: :once, room_at: 12)

    [3, 6].each do |frames|
      assert_equal [rgb5(*BLUE_FADED)], game_player.run(title, frames: frames).screen.shown.uniq
      assert_backends_agree(title, frames: frames, console_frames: frames + 2)
    end
  end

  # The walker has moved on from where it started, and what is left there is the mist as the
  # rest of the screen shows it — not a patch of the mist drawn see-through.
  def test_a_sprite_leaves_the_solid_mist_behind_it_under_a_fade
    shown = game_player.run(faded_title_then_misty_room, frames: 14).screen.shown

    assert_equal rgb5(*SOLID_MIST_FADED), shown[(41 * 240) + 41], "where the walker started"
    assert_equal [rgb5(*SOLID_MIST_FADED), rgb5(16, 0, 0)].sort, shown.uniq.sort,
                 "one colour of mist everywhere, and the walker's red, both half way to black"
  end

  # The fade is the display's and the room's see-through layer is the display's too, the
  # same piece of it. A screen taking over sets its layers up, and must not take the fade's
  # place while doing so: both backends show the room dark, with the mist solid, on the
  # frames before, on and after the room takes over.
  def test_a_fade_left_on_stays_as_a_see_through_screen_takes_over
    room = faded_title_then_misty_room
    [2, 3, 4, 5, 8].each do |frames|
      assert_backends_agree(room, frames: frames, console_frames: frames + 1)
    end
  end

  # Both backends agree on the game at each of +frames+, a fade or a see-through mix in force.
  private def assert_backends_agree_through_the_fade(game, frames)
    frames.each { |at| assert_backends_agree(game, frames: at, console_frames: at + 1) }
  end

  # The same in a game whose rooms each tell the display what they blend on every pass: the
  # fade is still there on the passes after the room took over, and lifts when it is lifted.
  def test_that_fade_stays_where_each_room_says_what_it_blends_every_pass
    room = faded_title_then_misty_room(rooms: :room) { |pass| (pass == 10).then { fade :black, 0 } }

    assert_backends_agree_through_the_fade(room, [5, 8, 10, 11, 14])
  end

  # In that game the fade can be lifted in a room that sees through nothing. What it hands
  # the blend back to is that room's layers, both solid, and not the misty room's.
  def test_that_fade_lifted_in_a_room_with_nothing_seen_through_leaves_its_layers_solid
    hall = faded_title_then_misty_room(rooms: :hall) { |pass| (pass == 6).then { fade :black, 0 } }

    assert_backends_agree_through_the_fade(hall, [5, 6, 7, 10])
    assert_equal rgb5(16, 8, 2), game_player.run(hall, frames: 10).screen.pixel(200, 100),
                 "the hall's upper layer in its own colour, with nothing behind it showing"
  end

  # ...and the room lifting it brings the mist back see-through, on the same frame on both.
  def test_lifting_that_fade_in_the_room_brings_the_layer_back_see_through
    room = faded_title_then_misty_room { |pass| (pass == 8).then { fade :black, 0 } }

    assert_backends_agree_through_the_fade(room, [7, 8, 9, 12])
    assert_equal seen_through_mist, game_player.run(room, frames: 12).screen.pixel(200, 100),
                 "the mist is seen through again, at full brightness"
  end

  # A TINT TAKES THE FADE'S PLACE as another fade would: a picture has one such effect at a
  # time, and the last one said is the one in force. So a room that tints, however little,
  # has ended the fade it arrived under, and its mist is seen through again from then on.
  def test_a_tint_said_in_the_room_ends_that_fade_and_the_layer_is_seen_through_again
    room = faded_title_then_misty_room { tint :red, 0 }

    assert_backends_agree_through_the_fade(room, [5, 8, 12])
    assert_equal seen_through_mist, game_player.run(room, frames: 12).screen.pixel(200, 100)
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

  def test_one_flash_does_not_cost_the_layer_for_the_rest_of_the_game
    %i[scenery sprite].each do |kind|
      screen = game_player.run(flashing_program(kind), frames: AFTER_THE_FLASH).screen

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

  # A SCREEN has one see-through layer, and the message names both. Two on different
  # screens are fine (see test_layer_two_amounts.rb); these two are on the same one.
  def test_a_second_see_through_layer_on_the_same_screen_is_refused
    tile = SOLID_TILE
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("LAYERS", out: StringIO.new, err: err) do
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
    RubyGBA::IR::Guardrails::Validator.new.run(program, autofix: false).warnings.map(&:check)
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
    finding = RubyGBA::IR::Guardrails::Validator.new
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

  def test_the_report_says_a_fade_walks_the_colours_and_keeps_the_layer
    assert_includes report_of(flashing_program(:scenery)), "walks the colours"
  end

  def test_the_report_says_a_placed_fade_takes_the_blend
    assert_includes report_of(placed_fade_program(50, 25)), "is solid until it lifts"
  end

  def test_the_report_leaves_both_out_when_nothing_fades
    report = report_of(scenery_program(40))

    refute_includes report, "walks the colours"
    refute_includes report, "is solid until it lifts"
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

  def test_a_scene_sees_through_its_own_layer
    assert_equal HALF_WHITE_OVER_RED,
                 shown(scenes_that_take_turns, *SCENERY_XY, frames: SWITCH_AT + 4),
                 "the scene's pane does not show the floor under it"
  end

  # The half that was wrong: the console was told to blend a layer number the pane is not
  # on, so it drew the pane solid and the floor under it simply was not there.
  def test_the_console_sees_through_a_scenes_own_layer_the_same
    assert_equal HALF_WHITE_OVER_RED,
                 console(scenes_that_take_turns, *SCENERY_XY, "SCNBLD", frames: SWITCH_AT + 6),
                 "the console drew the scene's pane solid"
  end

  def test_the_two_backends_draw_the_same_screen_when_a_scene_sees_through_a_layer
    assert_backends_agree(scenes_that_take_turns, frames: SWITCH_AT + 4)
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

  # A tint said on the title is still in force as the room takes over: both backends tint the
  # room, by walking its colors, from its first frame.
  def test_a_tint_left_on_from_the_title_tints_the_room
    game = title_and_misty_room(first: :title, swap_at: 4, title: ->(_) { tint :red, 50 })
    assert_backends_agree_through_the_fade(game, [3, 4, 5, 8])
    untinted = title_and_misty_room(first: :title, swap_at: 4)

    refute_equal game_player.run(untinted, frames: 8).screen.pixel(200, 100),
                 game_player.run(game, frames: 8).screen.pixel(200, 100), "the room is tinted"
  end

  # A flash on the title shows there, done by the display.
  def test_a_flash_on_the_title_shows_on_the_title
    game = title_and_misty_room(first: :title, swap_at: 12, title: ->(pass) { (pass == 3).then { flash_screen frames: 8 } })
    assert_backends_agree_through_the_fade(game, [3, 4, 5, 7, 9, 11])
  end

  # A flash said on the title's last pass reaches the room's first frame, and walks on in the
  # room's colors from there.
  def test_a_flash_from_the_title_goes_on_in_the_room
    game = title_and_misty_room(first: :title, swap_at: 4, title: ->(pass) { (pass == 3).then { flash_screen frames: 8 } })
    assert_backends_agree_through_the_fade(game, [3, 4, 5, 6, 9])
  end

  # A fade out in the room leaves the title that follows it dark, until something lifts it.
  def test_a_fade_out_in_the_room_leaves_the_title_dark
    game = title_and_misty_room(first: :room, swap_at: 8, room: ->(pass) { (pass == 3).then { fade_out frames: 4 } })
    assert_backends_agree_through_the_fade(game, [4, 6, 7, 8, 9, 12])
    assert_equal [0], game_player.run(game, frames: 10).screen.shown.uniq, "the title, faded all the way to black"
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

  def test_each_room_is_seen_through_by_its_own_amount_from_the_frame_it_takes_over
    [3, 4, 5, 8, 9].each { |frames| assert_backends_agree(two_misty_rooms, frames: frames) }
  end

  # A sprite shows the numbers of the pass before, so on the frame the next room takes over
  # the leaving room's walker is still drawn — over the new room's scenery, which went up
  # after it in that frame — and gone the frame after.
  def test_a_leaving_rooms_sprite_is_drawn_over_the_next_rooms_scenery_for_one_frame
    rooms = two_misty_rooms(walker: true)
    [3, 4, 5].each { |frames| assert_backends_agree(rooms, frames: frames) }
    green = RubyGBA::Graphics::Color.resolve(:green)

    assert_includes game_player.run(rooms, frames: 4).screen.shown, green, "the walker on the frame the fog takes over"
    refute_includes game_player.run(rooms, frames: 5).screen.shown, green, "and gone the frame after"
  end

  # The whole round from a plain bitmap title: the misty room, the foggy one, and the misty one
  # again, compared on every frame a room takes over and the one after.
  def test_rooms_after_a_title_agree_on_every_change_of_room
    rooms = two_misty_rooms(walker: true, title: true)
    [2, 3, 4, 6, 7, 9, 10, 12].each { |frames| assert_backends_agree(rooms, frames: frames, console_frames: frames + 1) }
  end

  # ...and the scene BEFORE it, which sees through nothing, must not have picked up the
  # blend. Its two backgrounds sit on the layers the dive's floor and pane later use, so a
  # blend set up once at boot would quietly make the banner see-through.
  def test_a_scene_that_sees_through_nothing_is_drawn_solid
    green = RubyGBA::Graphics::Color.resolve(:green)

    assert_equal green, shown(scenes_that_take_turns, *SCENERY_XY, frames: 2),
                 "the banner scene is blended on the oracle"
    assert_equal green, console(scenes_that_take_turns, *SCENERY_XY, "SCNSLD", frames: 3),
                 "the banner scene is blended on the console"
  end
end
