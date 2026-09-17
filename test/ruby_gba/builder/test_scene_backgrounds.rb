# frozen_string_literal: true

require "test_helper"
require "differential"

# A SCENE OWNS THE BACKGROUNDS DECLARED INSIDE IT, the way it already owns the sprites
# and the HUD text declared there: they are on screen while that scene is the active
# state and not otherwise.
#
# That is what makes a game with many rooms writable — each room's scenery declared where
# it belongs — and it is what decides how many background layers a game may have at all.
# The console holds four scrolling layers AT ONCE, so what has to fit is one scene's
# worth, not the whole game's, exactly as the 32K of sprite pictures already works.
class TestSceneBackgrounds < Minitest::Test
  include Differential

  SOLID_TILE = (("#" * 8) + "\n").freeze * 8

  RED = RubyGBA::Graphics::Color.resolve(:red)
  BLUE = RubyGBA::Graphics::Color.resolve(:blue)

  MIDDLE = [120, 80].freeze

  # The frame the game moves from the first scene to the second.
  SWITCH_AT = 4

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # Two scenes that take turns, +per_scene+ full-screen scrolling backgrounds in each.
  # The last one declared in a scene is the one in front, so it is the colour that shows.
  private def two_scenes(per_scene)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      tiles :red_set, "#" => :red_art
      tiles :blue_set, "#" => :blue_art
      map = Array.new(20) { "#" * 30 }
      scene(:one) { per_scene.times { |i| background :"one_#{i}", tiles: :red_set, map: map } }
      scene(:two) { per_scene.times { |i| background :"two_#{i}", tiles: :blue_set, map: map } }
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick > SWITCH_AT).then { state.set! 1 }
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
  end

  private def shown(prog, frames) = Reference.new.run(prog, frames: frames).screen.pixel(*MIDDLE)

  private def on_console(prog, name, frames)
    assert_emulator_loads_rom(assemble_rom(prog, name: name), frames: frames).pixel_gba(*MIDDLE)
  end

  # THE ONE THE BEAD IS ABOUT: four scrolling backgrounds in each of two scenes. The
  # console never has to hold more than one scene's worth, so this is four layers at a
  # time and not eight.
  def test_two_scenes_can_have_four_scrolling_backgrounds_each
    assert_equal RED, shown(two_scenes(4), SWITCH_AT)
    assert_equal BLUE, shown(two_scenes(4), SWITCH_AT + 4)
  end

  def test_the_console_shows_four_scrolling_backgrounds_in_each_of_two_scenes_too
    assert_equal RED, on_console(two_scenes(4), "SCNBG1", SWITCH_AT)
    assert_equal BLUE, on_console(two_scenes(4), "SCNBG2", SWITCH_AT + 6)
  end

  # SCENERY EVERY SCREEN SHOWS IS IN EVERY SCREENFUL, so it is what each scene has left
  # that the scene's own has to fit in. A game with a backdrop up throughout and three
  # backgrounds in each of two scenes is four layers at a time, and fits exactly.
  private def a_backdrop_and_two_scenes(per_scene)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:green_art, "#" => :green) { tile }
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      tiles :green_set, "#" => :green_art
      tiles :red_set, "#" => :red_art
      tiles :blue_set, "#" => :blue_art
      spotty = Array.new(20) { |r| (0...30).map { |c| (r + c).even? ? "#" : " " }.join }
      full = Array.new(20) { "#" * 30 }
      background :backdrop, tiles: :green_set, map: full
      scene(:one) { per_scene.times { |i| background :"one_#{i}", tiles: :red_set, map: spotty } }
      scene(:two) { per_scene.times { |i| background :"two_#{i}", tiles: :blue_set, map: spotty } }
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick > SWITCH_AT).then { state.set! 1 }
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
  end

  GREEN = RubyGBA::Graphics::Color.resolve(:green)

  def test_a_backdrop_every_screen_shows_stays_up_across_both_scenes
    screen = Reference.new.run(a_backdrop_and_two_scenes(3), frames: SWITCH_AT + 4).screen

    assert_equal BLUE, screen.pixel(0, 0), "the scene's own scenery is in front"
    assert_equal GREEN, screen.pixel(8, 0), "the always-there backdrop shows through its holes"
  end

  def test_the_console_keeps_the_backdrop_up_across_both_scenes_too
    v = assert_emulator_loads_rom(assemble_rom(a_backdrop_and_two_scenes(3), name: "SCNBG6"),
                                  frames: SWITCH_AT + 6)

    assert_equal BLUE, v.pixel_gba(0, 0), "the scene's own scenery is in front"
    assert_equal GREEN, v.pixel_gba(8, 0), "the always-there backdrop shows through its holes"
  end

  # ...and one more in each scene is five at a time, which is refused — naming the scene,
  # because "this game declares five" would send the author counting the whole program.
  def test_one_too_many_in_a_scene_is_refused_and_names_the_scene
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(a_backdrop_and_two_scenes(4)) }

    assert_includes error.message, "at one time"
    assert_includes error.message, ":one", "the message does not say which scene ran out"
  end

  # SCENES OF DIFFERENT SIZES, which is where an always-there backdrop can go wrong and
  # evenly-sized scenes cannot show it. The backdrop is drawn once and carries ONE paint
  # order, while the scenes it appears over hold different numbers of layers — so an order
  # read off the quiet scene puts the backdrop in FRONT of the busy scene's back layer.
  # Read where only the busy scene's backmost layer draws.
  private def uneven_over_a_backdrop(first, second)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:green_art, "#" => :green) { tile }
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      tiles :green_set, "#" => :green_art
      tiles :red_set, "#" => :red_art
      tiles :blue_set, "#" => :blue_art
      full = Array.new(20) { "#" * 30 }
      # The busy scene's layers are stacked so that only its BACKMOST one draws at the far
      # left: each later one starts a column further in.
      column = ->(n) { Array.new(20) { |_r| (0...30).map { |c| c == n ? "#" : " " }.join } }
      background :backdrop, tiles: :green_set, map: full
      scene(:one) { first.times { |i| background :"one_#{i}", tiles: :red_set, map: column.call(i) } }
      scene(:two) { second.times { |i| background :"two_#{i}", tiles: :blue_set, map: column.call(i) } }
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick > SWITCH_AT).then { state.set! 1 }
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
  end

  def test_a_backdrop_stays_behind_the_busy_scenes_backmost_layer
    screen = Reference.new.run(uneven_over_a_backdrop(1, 3), frames: SWITCH_AT + 4).screen

    assert_equal BLUE, screen.pixel(0, 0), "the backdrop was drawn over the scene's back layer"
  end

  def test_the_console_keeps_the_backdrop_behind_it_too
    v = assert_emulator_loads_rom(assemble_rom(uneven_over_a_backdrop(1, 3), name: "SCNBG7"),
                                  frames: SWITCH_AT + 6)

    assert_equal BLUE, v.pixel_gba(0, 0), "the backdrop was drawn over the scene's back layer"
  end

  # A DECLARED STACK IS COUNTED PER SCREEN TOO. The console keeps four depths as well as
  # four layers, and both are spent while something is being drawn — so a game that names
  # its stack and puts three backgrounds in each of two scenes must not be refused at six.
  def test_a_named_stack_is_counted_per_screen_as_well
    tile = SOLID_TILE
    prog = program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      tiles :red_set, "#" => :red_art
      tiles :blue_set, "#" => :blue_art
      map = Array.new(20) { "#" * 30 }
      layers :o0, :o1, :o2, :t0, :t1, :t2
      scene(:one) { 3.times { |i| layer(:"o#{i}") { background :"one_#{i}", tiles: :red_set, map: map } } }
      scene(:two) { 3.times { |i| layer(:"t#{i}") { background :"two_#{i}", tiles: :blue_set, map: map } } }
      var :state, 0
      game_loop { case_var(:state) { when_val 0, :one; when_val 1, :two } }
    end

    GBA.new.lower(prog) # six layers over two scenes is three at a time, and fits
  end

  # A SCENE THAT USES FEWER LAYERS THAN THE LAST ONE. This is the case scene-by-scene
  # numbering introduces and a game cannot see coming: the layers the busy scene filled are
  # still switched on when the quiet one takes over, still pointed at the busy scene's
  # maps. A game walking from a parallax field into a plain room would show the field's
  # far layers through the room's floor.
  private def uneven_scenes(first, second)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      tiles :red_set, "#" => :red_art
      tiles :blue_set, "#" => :blue_art
      # The quiet scene's background has HOLES in it, so anything still being drawn behind
      # shows through. A full-screen one would cover a leak rather than reveal it.
      spotty = Array.new(20) { |r| (0...30).map { |c| (r + c).even? ? "#" : " " }.join }
      full = Array.new(20) { "#" * 30 }
      scene(:one) { first.times { |i| background :"one_#{i}", tiles: :red_set, map: full } }
      scene(:two) { second.times { |i| background :"two_#{i}", tiles: :blue_set, map: spotty } }
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick > SWITCH_AT).then { state.set! 1 }
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
  end

  # Through the holes there is nothing left to draw, so the backdrop shows — never the
  # scene before's scenery. The map alternates by CELL and a cell is 8 pixels, so these are
  # a filled cell and the hole beside it.
  BACKDROP = 0
  FILLED_CELL = [0, 0].freeze
  THE_HOLE_BESIDE_IT = [8, 0].freeze

  def test_a_quiet_scene_does_not_show_the_busy_scenes_leftover_layers
    screen = Reference.new.run(uneven_scenes(3, 1), frames: SWITCH_AT + 4).screen

    assert_equal BLUE, screen.pixel(*FILLED_CELL), "the quiet scene's own background is drawn"
    assert_equal BACKDROP, screen.pixel(*THE_HOLE_BESIDE_IT),
                 "the busy scene's layers are still showing through"
  end

  def test_the_console_does_not_show_them_either
    v = assert_emulator_loads_rom(assemble_rom(uneven_scenes(3, 1), name: "SCNBG5"), frames: SWITCH_AT + 6)

    assert_equal BLUE, v.pixel_gba(*FILLED_CELL), "the quiet scene's own background is drawn"
    assert_equal BACKDROP, v.pixel_gba(*THE_HOLE_BESIDE_IT),
                 "the busy scene's layers are still showing through"
  end

  # A SCENE'S BACKGROUND GOES AWAY WITH THE SCENE. Asserted on its own and at one
  # background per scene, because it is the plainest statement of the rule the count above
  # depends on: if the first scene's scenery were still being drawn, its layers would
  # still be spoken for and the count could never be per scene.
  def test_the_first_scenes_background_stops_being_drawn_when_the_second_takes_over
    assert_equal RED, shown(two_scenes(1), SWITCH_AT)
    assert_equal BLUE, shown(two_scenes(1), SWITCH_AT + 4)
  end

  def test_the_console_stops_drawing_it_too
    assert_equal RED, on_console(two_scenes(1), "SCNBG3", SWITCH_AT)
    assert_equal BLUE, on_console(two_scenes(1), "SCNBG4", SWITCH_AT + 6)
  end

  # A SCENE'S BACKGROUND MOVES LIKE ANY OTHER. Scrolling one is what a room IS — a world
  # bigger than the screen with a window over it — so scenery declared in the scene it
  # belongs to has to scroll there, or declaring it where it belongs costs the game its
  # movement.
  #
  # The same background twice, once at the top level and once inside a scene that runs
  # every frame, each scrolled one pixel a frame. Said as "the two agree" rather than
  # against a written-down offset, so no wrong-but-matching number can satisfy it.
  private def scrolling_program(in_a_scene:)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      tiles :set, "#" => :red_art, "." => :blue_art
      # Stripes a tile wide, so a scroll of a few pixels is plain to see in one row.
      striped = Array.new(20) { |r| (0...30).map { |c| (r + c).even? ? "#" : "." }.join }
      if in_a_scene
        scene(:play) do
          field = background :field, tiles: :set, map: striped
          field.scroll_by 1, 0
        end
        var :state, 0
        game_loop { case_var(:state) { when_val 0, :play } }
      else
        field = background :field, tiles: :set, map: striped
        game_loop { field.scroll_by 1, 0 }
      end
    end
  end

  # Three tiles of the top row, which is enough to see a scroll of a few pixels and short
  # enough to read in a failure message. Either backend's reader answers to `pixel_gba`
  # or `pixel`, so the block says which.
  ACROSS_THREE_TILES = (0...24)

  private def top_row(&pixel) = ACROSS_THREE_TILES.map(&pixel)

  SCROLLED_FOR = 9

  def test_a_background_declared_inside_a_scene_scrolls
    at_top_level = Reference.new.run(scrolling_program(in_a_scene: false), frames: SCROLLED_FOR).screen
    in_a_scene = Reference.new.run(scrolling_program(in_a_scene: true), frames: SCROLLED_FOR).screen

    assert_equal top_row { |x| at_top_level.pixel(x, 0) }, top_row { |x| in_a_scene.pixel(x, 0) },
                 "the scene's background did not scroll the way the same one at the top level did"
  end

  # The console is drawing while it boots and reaches its first pass a frame later than the
  # interpreter does, so both runs are given that frame — the same offset the differential
  # helper applies for a tiled screen, named here because this test does not use it.
  CONSOLE_LAG = Differential::BOOT_FRAMES.fetch(:tiled)

  def test_the_console_scrolls_a_scenes_background_too
    at_top_level = assert_emulator_loads_rom(
      assemble_rom(scrolling_program(in_a_scene: false), name: "SCNSC1"), frames: SCROLLED_FOR + CONSOLE_LAG
    )
    in_a_scene = assert_emulator_loads_rom(
      assemble_rom(scrolling_program(in_a_scene: true), name: "SCNSC2"), frames: SCROLLED_FOR + CONSOLE_LAG
    )

    assert_equal top_row { |x| at_top_level.pixel_gba(x, 0) }, top_row { |x| in_a_scene.pixel_gba(x, 0) },
                 "the console did not scroll the scene's background"
  end

  # A CELL CHANGED IN A SCENE'S BACKGROUND STAYS CHANGED. The other half of the same
  # cause: putting a layer up sends its whole map again, so doing it every frame put back
  # every cell the game had changed since. A door that opens, a pot that breaks, a heart
  # that empties — each is one cell, and each was undone on the next frame.
  #
  # THE TWO BACKENDS DISAGREED ABOUT THIS ONE, which is the reason both halves are asserted
  # rather than just the console's. The interpreter paints from its own copy of the map, so
  # a changed cell was always painted back changed and this was already true there; the
  # console re-sent the map and lost it. Measured before the fix: the interpreter kept the
  # cell and the console put it back. So the interpreter was the right answer all along and
  # the console now matches it.
  private def changing_program
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      tiles :set, "#" => :red_art, "." => :blue_art
      map = Array.new(20) { "#" * 30 }
      tick = var :tick, 0
      scene(:play) do
        room = background :room, tiles: :set, map: map
        # One cell turns blue on the second frame and must stay blue after that.
        (tick == 2).then { room.set_tile 0, 0, "." }
      end
      var :state, 0
      game_loop do
        tick.add! 1
        case_var(:state) { when_val 0, :play }
      end
    end
  end

  def test_a_cell_changed_in_a_scenes_background_stays_changed
    seen = (2..8).map { |f| Reference.new.run(changing_program, frames: f).screen.pixel(0, 0) }

    assert_equal [BLUE], seen.uniq, "the changed cell was put back by the next frame"
  end

  def test_the_console_keeps_the_changed_cell_too
    v = assert_emulator_loads_rom(assemble_rom(changing_program, name: "SCNTIL"), frames: 10)

    assert_equal BLUE, v.pixel_gba(0, 0), "the console put the changed cell back"
  end

  # A BACKGROUND THAT BELONGS TO NO SCENE IS NOT COVERED BY ANY OF THIS, and the two
  # backends have to say so together. One declared in a plain routine that the frame calls
  # is re-reached every pass exactly as a scene's was, and it is put up again every time —
  # the cartridge has no way to know it is already up, so the interpreter must not pretend
  # it does. What matters here is not which answer they give but that it is the same one:
  # a picture that is right on the oracle and wrong on the console is the worst outcome
  # there is, because a game's own tests would pass.
  private def in_a_plain_routine
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      tiles :set, "#" => :red_art, "." => :blue_art
      striped = Array.new(20) { |r| (0...30).map { |c| (r + c).even? ? "#" : "." }.join }
      func(:put_it_up) do
        field = background :field, tiles: :set, map: striped
        field.scroll_by 1, 0
      end
      game_loop { call :put_it_up }
    end
  end

  def test_the_backends_agree_about_a_background_in_a_plain_routine
    assert_backends_agree(in_a_plain_routine, frames: SCROLLED_FOR)
  end

  # A TILED SCENE, AWAY TO A BITMAP SCREEN, AND BACK. The two kinds of screen share the
  # console's video memory in ways that cannot both be live, so crossing between them wipes
  # what was there — and the scenery has to be put up again on the way back rather than
  # taken as still standing.
  private def there_and_back
    tile = SOLID_TILE
    program do
      image(:red_art, "#" => :red) { tile }
      tiles :set, "#" => :red_art
      screen :tiled
      full = Array.new(20) { "#" * 30 }
      scene(:tiled_one) { background :field, tiles: :set, map: full }
      scene(:bitmap_one) do
        screen :bitmap
        clear_screen :black
      end
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick == 3).then { state.set! 1 } # away to the bitmap screen
        (tick == 6).then { state.set! 0 } # ...and back
        case_var(:state) do
          when_val 0, :tiled_one
          when_val 1, :bitmap_one
        end
      end
    end
  end

  def test_a_scenes_background_comes_back_after_a_bitmap_screen
    assert_equal RED, Reference.new.run(there_and_back, frames: 9).screen.pixel(0, 0),
                 "the scenery never came back after the other kind of screen wiped it"
  end

  def test_the_console_brings_it_back_too
    v = assert_emulator_loads_rom(assemble_rom(there_and_back, name: "SCNTHR"), frames: 10)

    assert_equal RED, v.pixel_gba(0, 0), "the console never brought the scenery back"
  end

  # ONE SCENE THAT TURNS A BACKGROUND, BESIDE ONE THAT STACKS FOUR SCROLLING ONES.
  #
  # The console arranges its tile layers one of two ways — four that scroll, or two that
  # scroll beside one that turns and resizes — and it is told which in one register, so it
  # can be told again whenever the screen changes. A retail cartridge does exactly this: a
  # title screen with something flying at the player, then a game played with nothing
  # turning at all.
  #
  # So the arrangement belongs to the scene, not to the cartridge. Counted for the whole
  # program, one turning background anywhere caps EVERY screen at two scrolling layers —
  # which a game cannot trade away, because the four in its play screen are four different
  # things at four different depths.
  private def a_turning_title_and_a_scrolling_game
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:sword_art, "#" => :white) { tile }
      image(:ground_art, "#" => :red) { tile }
      image(:letters_art, "#" => :blue) { tile }
      tiles :sword, "#" => :sword_art
      tiles :ground, "#" => :ground_art
      tiles :letters, "#" => :letters_art
      full = Array.new(16) { "#" * 16 }
      # The play scene's four layers, the frontmost drawn in its own colour so which one
      # shows says the whole stack landed.
      spotty = Array.new(20) { |r| (0...30).map { |c| (r + c).even? ? "#" : " " }.join }
      layers :rays, :name, :sword, :ground, :scenery, :panel, :letters
      ratio = var :ratio, 1.0

      scene :title do
        layer(:rays) { background :rays, tiles: :ground, map: full }
        layer(:name) { background :name, tiles: :ground, map: full }
        layer(:sword) { background(:sword, tiles: :sword, map: full).scale(ratio) }
      end

      scene :play do
        layer(:ground)  { background :ground,  tiles: :ground,  map: full }
        layer(:scenery) { background :scenery, tiles: :ground,  map: full }
        layer(:panel)   { background :panel,   tiles: :ground,  map: full }
        layer(:letters) { background :letters, tiles: :letters, map: spotty }
      end

      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick > SWITCH_AT).then { state.set! 1 }
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
  end

  def test_a_turning_title_can_sit_beside_a_game_with_four_scrolling_layers
    screen = Reference.new.run(a_turning_title_and_a_scrolling_game, frames: SWITCH_AT + 4).screen

    assert_equal BLUE, screen.pixel(0, 0), "the play scene's frontmost layer is not drawn"
  end

  def test_the_console_holds_both_arrangements_in_one_cartridge
    v = assert_emulator_loads_rom(
      assemble_rom(a_turning_title_and_a_scrolling_game, name: "SCNARR"), frames: SWITCH_AT + 6
    )

    assert_equal BLUE, v.pixel_gba(0, 0), "the play scene's frontmost layer is not drawn"
  end

  # ...and the console is really told so, read off its own display register rather than
  # inferred from the picture. Which arrangement is in force sits in the low three bits and
  # which layers are switched on in the byte above, so this says in one reading that the
  # console changed arrangement AND that the fourth layer is off in the one that has no
  # fourth layer — a layer left switched on there means nothing to the hardware and is the
  # half of this that a picture can hide.
  include RubyGBA::Cartridge::Constants # REG_DISPCNT, and the bits below it

  ARRANGEMENT = 0x7
  private def layers_on(value) = (0..3).select { |bg| value.anybits?(1 << (8 + bg)) }

  def test_the_console_is_told_a_different_arrangement_in_each_scene
    v = assert_emulator_loads_rom(
      assemble_rom(a_turning_title_and_a_scrolling_game, name: "SCNDSP"), frames: SWITCH_AT
    )
    title = v.mem16(REG_DISPCNT)
    v.step(6)
    play = v.mem16(REG_DISPCNT)

    assert_equal [1, [0, 1, 2]], [title & ARRANGEMENT, layers_on(title)],
                 "the title scene is not the arrangement that holds a turning layer"
    assert_equal [0, [0, 1, 2, 3]], [play & ARRANGEMENT, layers_on(play)],
                 "the play scene did not get all four scrolling layers"
  end

  # Every pixel of the screen, not the two sampled above. A layer left switched on, or one
  # numbered differently by the two backends, shows up here and nowhere else — the pixels
  # picked by hand are the ones somebody already thought to look at.
  def test_the_two_backends_draw_the_same_screen_after_the_scene_changes
    assert_backends_agree(two_scenes(4), frames: SWITCH_AT + 4)
    assert_backends_agree(uneven_scenes(3, 1), frames: SWITCH_AT + 4)
    assert_backends_agree(a_backdrop_and_two_scenes(3), frames: SWITCH_AT + 4)
  end

  # ...and the same for a scene's background that MOVES and one whose cells CHANGE. Both
  # halves above compare a backend against itself — the scene's picture against the top
  # level's on the same backend — which a wrong-but-consistent answer would satisfy. This
  # is the half that cannot: the two backends reached the changed cell by different routes
  # and disagreed about it until now.
  def test_the_two_backends_draw_the_same_moving_and_changing_scene
    assert_backends_agree(scrolling_program(in_a_scene: true), frames: SCROLLED_FOR)
    assert_backends_agree(changing_program, frames: SCROLLED_FOR)
  end

  # ...and the same for the two arrangements in one cartridge, which is where a layer left
  # switched on by the scene before would show — the mixed arrangement has no fourth layer,
  # so one left on there means nothing to the hardware and everything to the picture.
  def test_the_two_backends_draw_the_same_screen_in_both_arrangements
    assert_backends_agree(a_turning_title_and_a_scrolling_game, frames: SWITCH_AT + 4)
  end

  # A SCENE'S BACKGROUND MUST NOT MOVE ANOTHER SCENE'S LAYER.
  #
  # Where a background SITS is a property of the console's layer, not of the background —
  # and scenes take turns with the layers. So a background belonging to a scene that is
  # not on screen must leave the scroll registers alone: two backgrounds sharing a layer
  # both write it every frame otherwise, and the second one declared wins. A title screen
  # of drifting scenery handing over to a game that starts at the top of its map had the
  # game's nought pinning the title still.
  private def a_drifting_title_and_a_still_game
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      tiles :red_set, "#" => :red_art
      tiles :both, "#" => :red_art, "o" => :blue_art
      striped = Array.new(32) { (0...32).map { |c| (c % 4).zero? ? "o" : "#" }.join }
      plain = Array.new(32) { "#" * 32 }
      layers :drifting, :still
      var :state, 0

      scene :title do
        drift = layer(:drifting) { background :drift, tiles: :both, map: striped }
        drift.scroll_by 2, 0
      end

      # The game's own scenery follows how far into its map you have walked, which is
      # nought at the start — and nought is what pinned the title still.
      scene :play do
        ground = layer(:still) { background :ground, tiles: :red_set, map: plain }
        ground.scroll_to 0, 0
      end

      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
  end

  # Read a row of the title, frame by frame: scenery that is drifting gives a different
  # row each frame, and scenery pinned still gives the same one over and over.
  private def rows_over_time(verifier, frames)
    (0...frames).map do
      row = (0...48).map { |x| verifier.pixel_gba(x, 8) }
      verifier.step
      row
    end
  end

  def test_the_console_keeps_a_scenes_scenery_drifting
    v = assert_emulator_loads_rom(assemble_rom(a_drifting_title_and_a_still_game, name: "SCNSCR"), frames: 3)

    assert_operator rows_over_time(v, 6).uniq.length, :>=, 4,
                    "the title's scenery is pinned still by a scene that is not on screen"
  end

  def test_the_two_backends_agree_about_a_scenes_drifting_scenery
    assert_backends_agree(a_drifting_title_and_a_still_game, frames: 6)
  end
end
