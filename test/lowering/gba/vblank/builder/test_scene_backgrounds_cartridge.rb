# frozen_string_literal: true

require "test_helper"
require "differential"
require "tmpdir"
require "all/vblank/builder/test_scene_backgrounds"

# A SCENE'S BACKGROUNDS ON THE ADVANCE'S CARTRIDGE: what its picture, its display registers
# and the order it writes them in come out as, read in the emulator. What a scene's
# backgrounds do, asked of every run, is in test/all/vblank/builder/test_scene_backgrounds.rb.
class TestSceneBackgroundsCartridge < Minitest::Test
  include Differential
  include SceneBackgroundGames

  private def on_console(prog, name, frames)
    assert_emulator_loads_rom(assemble_rom(prog, name: name), frames: frames).pixel_gba(*MIDDLE)
  end

  def test_the_console_shows_four_scrolling_backgrounds_in_each_of_two_scenes_too
    assert_equal RED, on_console(two_scenes(4), "SCNBG1", SWITCH_AT)
    assert_equal BLUE, on_console(two_scenes(4), "SCNBG2", SWITCH_AT + 6)
  end

  # A scene that comes back after a bare one puts its scenery up as declared
  # (test_a_scene_back_after_a_bare_one_puts_its_scenery_up_as_declared), on the console too.
  def test_the_console_puts_the_scenery_back_after_a_bare_scene
    assert_equal RED, on_console(a_door_opened_then_a_bare_scene_then_back, "SCNBG7", SWITCH_AT + 10)
  end

  def test_the_console_keeps_the_backdrop_up_across_both_scenes_too
    v = assert_emulator_loads_rom(assemble_rom(a_backdrop_and_two_scenes(3), name: "SCNBG6"),
                                  frames: SWITCH_AT + 6)

    assert_equal BLUE, v.pixel_gba(0, 0), "the scene's own scenery is in front"
    assert_equal GREEN, v.pixel_gba(8, 0), "the always-there backdrop shows through its holes"
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

  def test_the_console_keeps_the_backdrop_behind_it_too
    v = assert_emulator_loads_rom(assemble_rom(uneven_over_a_backdrop(1, 3), name: "SCNBG7"),
                                  frames: SWITCH_AT + 6)

    assert_equal BLUE, v.pixel_gba(0, 0), "the backdrop was drawn over the scene's back layer"
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

  def test_the_console_does_not_show_them_either
    v = assert_emulator_loads_rom(assemble_rom(uneven_scenes(3, 1), name: "SCNBG5"), frames: SWITCH_AT + 6)

    assert_equal BLUE, v.pixel_gba(*FILLED_CELL), "the quiet scene's own background is drawn"
    assert_equal BACKDROP, v.pixel_gba(*THE_HOLE_BESIDE_IT),
                 "the busy scene's layers are still showing through"
  end

  def test_the_console_stops_drawing_it_too
    assert_equal RED, on_console(two_scenes(1), "SCNBG3", SWITCH_AT)
    assert_equal BLUE, on_console(two_scenes(1), "SCNBG4", SWITCH_AT + 6)
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

  def test_the_console_keeps_the_changed_cell_too
    v = assert_emulator_loads_rom(assemble_rom(changing_program, name: "SCNTIL"), frames: 10)

    assert_equal BLUE, v.pixel_gba(0, 0), "the console put the changed cell back"
  end

  def test_the_console_puts_it_up_as_declared_too
    v = assert_emulator_loads_rom(assemble_rom(leaving_and_coming_back, name: "SCNBAK"), frames: 11)

    assert_equal RED, v.pixel_gba(0, 0), "the console kept the changed cell across leaving the scene"
  end

  def test_the_console_shows_the_first_map_and_can_choose_again
    rom = assemble_rom(choosing_a_map_and_coming_back, name: "SCNMAP")
    v = assert_emulator_loads_rom(rom, frames: 5, vars: rom.var_addresses)
    assert_equal 1, v.var(:seen), "the other map was never chosen, so nothing below means anything"

    v.step(6)
    assert_equal RED, v.pixel_gba(0, 0), "the console kept the map chosen before leaving"
    assert_equal 0, v.var(:seen), "the console still said the other map was showing"

    v.step(5)
    assert_equal BLUE, v.pixel_gba(0, 0), "choosing the map again after coming back did nothing"
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
  include VBlank::Console::Hardware # REG_DISPCNT, and the bits below it

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

  # A SCENE THAT DECLARES NOTHING IS STILL A SCREEN.
  #
  # A layer is switched on at boot for every background in the program, and a layer
  # belonging to a scene that has not run yet has never been told where its map is. Nought
  # is not "nowhere": it points at the very start of video memory, which is where the tile
  # PICTURES live — so the layer draws the art as though it were a grid, in front of
  # everything, and the blank tiles among it show the backdrop colour through the game.
  #
  # It lasts the whole run rather than one frame because a scene that declares no scenery
  # and no sprites was not counted as a screen at all, so the per-scene layer work had one
  # screen to look at, found nothing to disagree about, and wrote nothing.
  BGCNT = [0x0400_0008, 0x0400_000A, 0x0400_000C, 0x0400_000E].freeze

  # Enough distinct pictures to fill the bottom of tile memory. With one picture per
  # background the art is all noughts down there, so the stray layer reads a grid of
  # noughts, draws tile 0, and is invisible while being just as wrong.
  private def a_scene_that_declares_nothing
    program do
      screen :tiled
      16.times do |n|
        image :"art_#{n}", "#" => :white, "." => :black do
          ((["#" * 8] * (n + 1)) + (["." * 8] * (7 - (n % 8)))).first(8).join("\n")
        end
      end
      tiles :every, (0...16).to_h { |n| [n.to_s(16), :"art_#{n}"] }
      tiles :one, "#" => :art_0
      layers :back, :panel

      layer(:back) { background :back, tiles: :every, map: Array.new(20) { "0123456789abcdef".chars.cycle.first(30).join } }

      state = var :state, 0
      waiting = var :waiting, SWITCH_AT

      scene :first do
        waiting.sub! 1
        (waiting == 0).then { state.set! 1 }
      end

      scene :second do
        layer(:panel) { background :panel, tiles: :one, map: Array.new(20) { " " * 30 } }
      end

      game_loop do
        case_var :state do
          when_val 0, :first
          when_val 1, :second
        end
      end
    end
  end

  # From the VERY FIRST frame, not from the frame the scene's own setup catches up. A
  # layer left on for one frame with no map of its own still draws the art as a grid, and
  # one frame of that is what a player sees as the game flickering on.
  def test_a_layer_of_a_scene_that_has_not_run_draws_nothing
    v = assert_emulator_loads_rom(assemble_rom(a_scene_that_declares_nothing, name: "SCNOFF"), frames: 1)

    3.times do |frame|
      display = v.mem16(REG_DISPCNT)
      (0..3).select { |bg| display.anybits?(1 << (8 + bg)) }.each do |bg|
        refute_equal 0, v.mem16(BGCNT[bg]),
                     "on frame #{frame + 1} layer #{bg} is on and has never been told where its map is"
      end
      v.step
    end
  end

  # A SCENE WITH NO SCENERY OF ITS OWN HAS NO LAYER SWITCHED ON.
  #
  # The one above is a scene that declares nothing while the game's scenery belongs to the
  # program, so every screen shows that scenery and every screen has a layer. This is the
  # other shape, and it is the ordinary one: a title made of sprites and words handing over
  # to a game that owns its rooms. That title's screen has no background at all, and a
  # screen with no background used to be given one anyway — the layer numbering falls back
  # to the first layer so that a tiled screen always has one on, which is right for a game
  # that never mentions scenes and wrong for a scene that genuinely draws none.
  #
  # A layer switched on has to be pointed somewhere, and nobody ever points that one: its
  # map base stays at nought, which is not "nowhere" but the very start of video memory,
  # where the tile pictures are. So the title screen draws the game's art as though it were
  # a grid, in front of the sprites, for as long as the title is up.
  private def a_title_with_no_scenery_of_its_own
    program do
      screen :tiled
      16.times do |n|
        image :"art_#{n}", "#" => :white, "." => :black do
          ((["#" * 8] * (n + 1)) + (["." * 8] * (7 - (n % 8)))).first(8).join("\n")
        end
      end
      tiles :every, (0...16).to_h { |n| [n.to_s(16), :"art_#{n}"] }
      layers :ground, :scenery, :panel

      state = var :state, 0
      waiting = var :waiting, SWITCH_AT

      # Nothing but the countdown: no background, no sprite, no word of text.
      scene :title do
        waiting.sub! 1
        (waiting == 0).then { state.set! 1 }
      end

      scene :play do
        rows = Array.new(20) { "0123456789abcdef".chars.cycle.first(30).join }
        layer(:ground)  { background :ground,  tiles: :every, map: rows }
        layer(:scenery) { background :scenery, tiles: :every, map: rows }
        layer(:panel)   { background :panel,   tiles: :every, map: rows }
      end

      game_loop do
        case_var :state do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
  end

  def test_a_scene_with_no_scenery_of_its_own_leaves_every_layer_off
    v = assert_emulator_loads_rom(assemble_rom(a_title_with_no_scenery_of_its_own, name: "SCNBARE"), frames: 1)

    3.times do |frame|
      assert_empty layers_on(v.mem16(REG_DISPCNT)),
                   "on frame #{frame + 1} the title has a layer on, and no map of its own to point it at"
      v.step
    end
  end

  # A LAYER IS POINTED AT ITS MAP BEFORE IT IS SWITCHED ON, NOT AFTER.
  #
  # Reading the registers once a frame cannot see this: both writes land in the same frame,
  # so by the time anybody looks the layer is on AND pointed. What the display does in
  # between is the whole question — the console draws the picture while the game is still
  # setting up, and a scene taking over has a map per layer to send, which is the longest
  # thing a game ever does in one go. Where that overruns the gap between pictures, a layer
  # switched on first spends the rest of the frame drawing the tile pictures as a grid.
  #
  # So the writes are read in the order they happened, with the row of the screen each one
  # landed on, off the console's own display log.
  private def display_register_writes(prog, name:, frames:)
    Dir.mktmpdir("scene-writes") do |dir|
      path = File.join(dir, "#{name.downcase}.gba")
      assemble_rom(prog, name: name).write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
      begin
        probe.watch_display
        probe.step(frames)
        return probe.display_writes.select { |w| w.kind == :register && WATCHED_REGISTERS.include?(w.address) }
      ensure
        probe.close
      end
    end
  end

  WATCHED_REGISTERS = ([VBlank::Console::Hardware::REG_DISPCNT] + BGCNT).freeze
  # Which layers were told to draw before they were told where to draw from, walking the
  # writes in the order the console saw them.
  private def switched_on_before_pointed(writes)
    pointed = []
    early = []
    writes.each do |write|
      if write.address == REG_DISPCNT
        # With the picture held off nothing is drawn, so nothing has been switched on yet.
        next if write.value.anybits?(FORCED_BLANK)

        early += (layers_on(write.value) - pointed).map { |layer| "layer #{layer} on at row #{write.row}" }
      else
        pointed |= [BGCNT.index(write.address)]
      end
    end
    early
  end

  def test_a_scene_points_its_layers_at_their_maps_before_switching_them_on
    writes = display_register_writes(a_title_with_no_scenery_of_its_own, name: "SCNORD", frames: SWITCH_AT + 3)

    assert_empty switched_on_before_pointed(writes),
                 "a layer was switched on with no map of its own yet"
  end

  # ...AND THE SAME AT POWER-ON, for scenery that belongs to the program and to no scene.
  #
  # The screen is declared before the backgrounds on it, so the display's settings are
  # written where `screen` is and each background's own where it is, afterwards. Setting a
  # background up is a copy of its whole map, so there are rows of the first picture
  # between the two — and a layer drawn in those rows with nothing pointing it draws the
  # tile pictures as a grid.
  private def scenery_of_the_program(looping:, screen_last: false)
    program do
      screen :tiled unless screen_last
      image :sky, "#" => :blue, "." => :transparent do
        (["##..##.."] * 8).join("\n")
      end
      image :brick, "#" => :red, "." => :black do
        (["#.#.#.#."] * 8).join("\n")
      end
      tiles :far, "s" => :sky
      tiles :near, "b" => :brick
      background :far, tiles: :far, map: ["s" * 30] * 20
      background :near, tiles: :near, map: ["b" * 30] * 20
      screen :tiled if screen_last
      looping ? game_loop {} : halt
    end
  end

  # A program with no game loop never waits for a frame, so nothing holds its picture off
  # while it sets up: it is shown as it is declared. Each layer has to wait for its own
  # background instead.
  def test_a_program_with_no_loop_points_its_layers_before_switching_them_on
    writes = display_register_writes(scenery_of_the_program(looping: false), name: "BOOTORD", frames: 3)

    assert_empty switched_on_before_pointed(writes),
                 "a layer was switched on with no map of its own yet"
    assert_equal [0, 1], layers_on(writes.reverse.find { |w| w.address == REG_DISPCNT }.value),
                 "and both are on once they have been"
  end

  # A background written ABOVE its `screen` has switched its layer on by the time the screen
  # is declared, and declaring the screen must not switch it off again.
  # It shows two backgrounds at once, which only the Advance has, and asks the Advance's own
  # display switches.
  def test_a_layer_declared_above_its_screen_stays_on
    program = scenery_of_the_program(looping: false, screen_last: true)
    assert_equal RED, game_player.run(program, frames: 2).screen.pixel(0, 0), "the front layer is not showing"
    v = assert_emulator_loads_rom(assemble_rom(program, name: "BOOTABV"), frames: 3)

    assert_equal [0, 1], layers_on(v.mem16(REG_DISPCNT)), "on the Advance's cartridge"
    assert_backends_agree(program, frames: 2)
  end

  # A program with a loop keeps its picture off until the first frame is set up, and by
  # then every layer has been pointed.
  def test_a_program_with_a_loop_shows_nothing_until_its_layers_are_pointed
    writes = display_register_writes(scenery_of_the_program(looping: true), name: "BOOTHLD", frames: 3)

    assert_empty switched_on_before_pointed(writes),
                 "a layer was showing with no map of its own yet"
  end

  # THE SIZE A SCENE'S BACKGROUND IS DECLARED AT IS PART OF DECLARING IT.
  #
  # A turning background is what asks the console for the arrangement that holds one, and
  # only the screen that wants that arrangement should be in it — so a title whose picture
  # flies at the player declares that picture inside the title's own scene. It then has to
  # be able to move: the whole animation is the size walking from magnified down to
  # natural.
  #
  # A scene's body runs on every frame the scene is active, so the size it was declared at
  # was put back at the top of every frame and whatever moved it got one step and no more.
  # Declaring it is not something a scene does sixty times a second, any more than sending
  # its map is.
  #
  # Judged on the picture, which is what the author sees. The map is blank but for two
  # marks, one where a magnified picture samples the middle of the screen and one where a
  # natural-sized picture samples the same point — so which colour shows at that one pixel
  # says how big the picture is, with no matrix arithmetic restated in the test.
  ZOOMED_IN = 16.0

  private def a_sword_that_flies_at_the_player(turning: false)
    marks = Array.new(32) { Array.new(32, " ") }
    marks[10][15] = "n" # what the middle of the screen samples while it is magnified
    marks[10][25] = "f" # ...and what it samples once the picture is its natural size
    map = marks.map(&:join)

    program do
      screen :tiled
      image(:near_art, "#" => :red) { SOLID_TILE }
      image(:far_art, "#" => :blue) { SOLID_TILE }
      tiles :marks, "n" => :near_art, "f" => :far_art
      layers :sword

      scene :title do
        sword = layer(:sword) do
          declared = background(:sword, tiles: :marks, map: map).scale(ZOOMED_IN)
          turning ? declared.rotate(90) : declared
        end
        sword.scale.approach! 1.0, 1.0
        sword.angle.approach! 0, 10 if turning
      end

      game_loop { case_var(:state) { when_val 0, :title } }
      var :state, 0
    end
  end

  # 80 pixels right of the middle, on the middle row: magnified it samples the near mark,
  # natural-sized it samples the far one.
  SAMPLED = [200, 80].freeze

  def test_the_console_eases_it_too
    v = assert_emulator_loads_rom(assemble_rom(a_sword_that_flies_at_the_player, name: "SCNSWD"), frames: 22)

    assert_equal BLUE, v.pixel_gba(*SAMPLED),
                 "the console was never told the eased size — the picture is still magnified"
  end

  # THE SCENERY'S MEMORY TAKES TURNS TOO, the way its layers do. The console keeps every
  # tile picture and every map a screen shows in 64K, and scenes that take turns never
  # need theirs there at the same time — so what has to fit is the busiest scene, not the
  # whole game. Four of the largest maps are 32K; two scenes of them are all 64K, which no
  # game could fit if both were counted at once.
  #
  # Each scene draws from a tile of its own colour, so going back to the first scene after
  # the second has had the memory shows whether the first scene's pictures were sent again.
  # When the scene changes, and when it changes back. Each reading is taken after the change has
  # settled, since what this asks is whose art is in the memory, not how soon it arrived (that is
  # the test of a scene's logic running from the frame it arrives, below).
  SECOND_SCENE_AT = 10
  FIRST_SCENE_AGAIN_AT = 25

  private def two_scenes_that_fill_the_memory_each
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      tiles :red_set, "#" => :red_art
      tiles :blue_set, "#" => :blue_art
      map = Array.new(64) { "#" * 64 }
      scene(:one) { 4.times { |i| background :"one_#{i}", tiles: :red_set, map: map } }
      scene(:two) { 4.times { |i| background :"two_#{i}", tiles: :blue_set, map: map } }
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick > SECOND_SCENE_AT).then { state.set! 1 }
        (tick > FIRST_SCENE_AGAIN_AT).then { state.set! 0 }
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
  end

  # A SCENE'S LOGIC RUNS ON EVERY FRAME, THE ONE IT ARRIVES ON INCLUDED, however much art it
  # brings. Sending that art is the console's work and the interpreter's is instant, so a copy
  # that ran long would take frames of game logic away on the console alone — a cursor that
  # waits a measured number of frames would wait longer, and the two backends would stop
  # agreeing. Counted here as how many times the scene has run by each frame, across a scene
  # change and at power-on, for a scene of the largest maps there are.
  private def a_scene_that_counts_its_frames(first:)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      tiles :red_set, "#" => :red_art
      tiles :blue_set, "#" => :blue_art
      big = Array.new(64) { "#" * 64 }
      runs = var :runs, 0
      scene(:small) { background :little, tiles: :red_set, map: ["#"] }
      scene(:big) do
        4.times { |i| background :"big_#{i}", tiles: :blue_set, map: big }
        runs.add! 1
      end
      state = var :state, first
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick > SWITCH_AT).then { state.set! 1 }
        case_var(:state) do
          when_val 0, :small
          when_val 1, :big
        end
      end
    end
  end

  private def runs_frame_by_frame(prog, name)
    rom = assemble_rom(prog, name: name)
    v = assert_emulator_loads_rom(rom, frames: Differential::BOOT_FRAMES[:tiled], vars: rom.var_addresses)
    console = Array.new(16) { v.step; v.var(:runs) }
    oracle = (1..16).map { |frames| game_player.run(prog, frames: frames)[:runs] }
    [oracle, console]
  end

  def test_a_scene_that_brings_a_lot_of_art_runs_from_the_frame_it_arrives
    oracle, console = runs_frame_by_frame(a_scene_that_counts_its_frames(first: 0), "SCNRUN1")

    assert_equal oracle, console, "the console lost frames of the scene's logic while its art was sent"
  end

  def test_the_first_scene_brings_its_art_without_losing_a_frame_either
    oracle, console = runs_frame_by_frame(a_scene_that_counts_its_frames(first: 1), "SCNRUN2")

    assert_equal oracle, console, "the console lost frames of the first scene's logic at power-on"
  end

  def test_the_console_holds_each_scenes_scenery_in_turn
    prog = two_scenes_that_fill_the_memory_each

    assert_equal [RED, BLUE, RED],
                 [[SECOND_SCENE_AT, "SCNMEM1"], [FIRST_SCENE_AGAIN_AT, "SCNMEM2"], [FIRST_SCENE_AGAIN_AT + 15, "SCNMEM3"]].map { |at, name| on_console(prog, name, at) }
  end
end
