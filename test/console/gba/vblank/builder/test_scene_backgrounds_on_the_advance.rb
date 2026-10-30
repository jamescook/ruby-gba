# frozen_string_literal: true

require "test_helper"
require "differential"

# The games these tests and the Advance's cartridge's tests both play
# (test/lowering/gba/vblank/builder/test_scene_backgrounds_on_the_advance_cartridge.rb).
module SceneBackgroundsOnTheAdvanceGames
  include SharedConstants

  RED = VBlank::Graphics::Color.resolve(:red)
  BLUE = VBlank::Graphics::Color.resolve(:blue)

  MIDDLE = [120, 80].freeze

  # The frame the game moves from the first scene to the second.
  SWITCH_AT = 4

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A SCENE WITH NO SCENERY OF ITS OWN still takes the screen from the one before: the first
  # scene's backdrop goes, and what every screen shows is what is left. A file screen's plain
  # backdrop must not stay up over the game it hands over to.
  private def a_backdrop_then_a_bare_scene
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      tiles :red_set, "#" => :red_art
      tiles :blue_set, "#" => :blue_art
      map = Array.new(20) { "#" * 30 }
      background :world, tiles: :red_set, map: map
      scene(:menu) { background :backdrop, tiles: :blue_set, map: map }
      scene(:walk) { nil }
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick > SWITCH_AT).then { state.set! 1 }
        case_var(:state) do
          when_val 0, :menu
          when_val 1, :walk
        end
      end
    end
  end
end

# The tests of test_scene_backgrounds.rb whose games show a second background while another is
# showing, or turn or resize a background, and a Game Boy Color's hardware cannot, so they play on
# the Advance's runs alone.
#
# What the cartridge shows, read in the emulator, is in
# test/lowering/gba/vblank/builder/test_scene_backgrounds_on_the_advance_cartridge.rb.
class TestSceneBackgroundsOnTheAdvance < Minitest::Test
  include Differential
  include SceneBackgroundsOnTheAdvanceGames

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

  private def shown(prog, frames) = game_player.run(prog, frames: frames).screen.pixel(*MIDDLE)

  # THE CASE THIS IS FOR: four scrolling backgrounds in each of two scenes. The
  # console never has to hold more than one scene's worth, so this is four layers at a
  # time and not eight.
  def test_two_scenes_can_have_four_scrolling_backgrounds_each
    assert_equal RED, shown(two_scenes(4), SWITCH_AT)
    assert_equal BLUE, shown(two_scenes(4), SWITCH_AT + 4)
  end

  def test_a_scene_with_no_scenery_of_its_own_takes_down_the_last_ones
    assert_equal BLUE, shown(a_backdrop_then_a_bare_scene, SWITCH_AT)
    assert_equal RED, shown(a_backdrop_then_a_bare_scene, SWITCH_AT + 4)
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

  GREEN = VBlank::Graphics::Color.resolve(:green)

  def test_a_backdrop_every_screen_shows_stays_up_across_both_scenes
    screen = game_player.run(a_backdrop_and_two_scenes(3), frames: SWITCH_AT + 4).screen

    assert_equal BLUE, screen.pixel(0, 0), "the scene's own scenery is in front"
    assert_equal GREEN, screen.pixel(8, 0), "the always-there backdrop shows through its holes"
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
    screen = game_player.run(uneven_over_a_backdrop(1, 3), frames: SWITCH_AT + 4).screen

    assert_equal BLUE, screen.pixel(0, 0), "the backdrop was drawn over the scene's back layer"
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
    screen = game_player.run(uneven_scenes(3, 1), frames: SWITCH_AT + 4).screen

    assert_equal BLUE, screen.pixel(*FILLED_CELL), "the quiet scene's own background is drawn"
    assert_equal BACKDROP, screen.pixel(*THE_HOLE_BESIDE_IT),
                 "the busy scene's layers are still showing through"
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
    screen = game_player.run(a_turning_title_and_a_scrolling_game, frames: SWITCH_AT + 4).screen

    assert_equal BLUE, screen.pixel(0, 0), "the play scene's frontmost layer is not drawn"
  end

  # Every pixel of the screen, not the two sampled above. A layer left switched on, or one
  # numbered differently by the two backends, shows up here and nowhere else — the pixels
  # picked by hand are the ones somebody already thought to look at.
  def test_the_two_backends_draw_the_same_screen_after_the_scene_changes
    assert_backends_agree(two_scenes(4), frames: SWITCH_AT + 4)
    assert_backends_agree(uneven_scenes(3, 1), frames: SWITCH_AT + 4)
    assert_backends_agree(a_backdrop_and_two_scenes(3), frames: SWITCH_AT + 4)
  end

  # ...and the same for the two arrangements in one cartridge, which is where a layer left
  # switched on by the scene before would show — the mixed arrangement has no fourth layer,
  # so one left on there means nothing to the hardware and everything to the picture.
  def test_the_two_backends_draw_the_same_screen_in_both_arrangements
    assert_backends_agree(a_turning_title_and_a_scrolling_game, frames: SWITCH_AT + 4)
  end

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

  def test_the_two_backends_agree_while_a_scene_that_declares_nothing_runs
    assert_backends_agree(a_scene_that_declares_nothing, frames: 2)
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

  # The interpreter has no layers to switch on, so its half of this is what the picture
  # comes out as: a scene that draws no scenery draws none, and the console now agrees.
  def test_the_two_backends_agree_while_a_scene_with_no_scenery_runs
    assert_backends_agree(a_title_with_no_scenery_of_its_own, frames: 2)
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

  def test_a_scene_owned_background_goes_on_easing_the_size_it_was_declared_at
    screen = game_player.run(a_sword_that_flies_at_the_player, frames: 20).screen

    assert_equal BLUE, screen.pixel(*SAMPLED),
                 "the picture never eased down to its natural size — it is still magnified"
  end

  # Every pixel, and both ends of the easing: the frame the scene takes over, where the
  # picture is magnified, and the frame it has arrived. Sampling one point says the size
  # walked; this says the two backends draw the same magnified picture all the way down.
  def test_the_two_backends_agree_while_the_picture_flies_at_the_player
    assert_backends_agree(a_sword_that_flies_at_the_player, frames: 3)
    assert_backends_agree(a_sword_that_flies_at_the_player, frames: 20)
  end

  # ...and a second turn written on the same line — `.scale(16.0).rotate(90)` — is part of
  # declaring it too, so the angle can be eased the same way the size can. It is one line
  # and it says one thing: this is how the picture starts.
  def test_a_turn_chained_onto_the_declaration_starts_the_picture_too
    screen = game_player.run(a_sword_that_flies_at_the_player(turning: true), frames: 20).screen

    assert_equal BLUE, screen.pixel(*SAMPLED),
                 "the picture never came upright — the angle it was declared at is put back every frame"
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

  def test_two_scenes_can_each_fill_the_scenery_memory
    prog = two_scenes_that_fill_the_memory_each

    assert_equal [RED, BLUE, RED], [SECOND_SCENE_AT, FIRST_SCENE_AGAIN_AT, FIRST_SCENE_AGAIN_AT + 15].map { |at| shown(prog, at) }
  end

  # ONE NAME IN TWO SCENES, BESIDE DIFFERENT SCENERY: :ground is declared behind a sky in the
  # first scene and alone in the second, so each scene lays its colours out differently, and
  # the second scene draws its :ground with other colours as it runs. Each scene shows its own
  # declaration in its own colours, and the first comes back as declared.
  private def one_ground_beside_other_scenery
    test = self
    program do
      screen :tiled
      colors :floor_own, %i[transparent red]
      colors :floor_dusk, %i[transparent white]
      image :floor, width: 8, height: 8, data: Array.new(64, :red), colors: :floor_own
      image(:sky_blue, "#" => :blue) { SOLID_TILE }
      image(:sky_yellow, "#" => :yellow) { SOLID_TILE }
      tiles :floor_tiles, "#" => :floor
      tiles :sky_tiles, "#" => :sky_blue, "o" => :sky_yellow
      grid = Array.new(20) { "#" * 30 }
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) do
        background :sky, tiles: :sky_tiles, map: ["#o" * 15] + ([" " * 30] * 19)
        background :ground, tiles: :floor_tiles, map: [" " * 30] + grid.drop(1)
      end
      scene(:two) do
        ground = background :ground, tiles: :floor_tiles, map: grid
        (tick > test.class::SWITCH_AT + 2).then { ground.draw_with :floor_dusk }
      end
      game_loop do
        tick.add! 1
        (tick == test.class::SWITCH_AT).then { state.set! 1 }
        (tick == test.class::SWITCH_AT * 3).then { state.set! 0 }
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
  end

  def test_a_name_in_two_scenes_beside_different_scenery_keeps_each_scenes_colours
    prog = one_ground_beside_other_scenery
    shown = ->(frames) { game_player.run(prog, frames: frames).screen }
    white = VBlank::Graphics::Color.resolve(:white)

    assert_equal [BLUE, RED], [shown.call(2).pixel(0, 0), shown.call(2).pixel(0, 8)], "the sky over the ground"
    assert_equal white, shown.call((SWITCH_AT * 2) + 2).pixel(0, 0), "the second scene's ground at dusk"
    assert_backends_agree(prog, frames: [2, SWITCH_AT + 1, (SWITCH_AT * 2) + 2, (SWITCH_AT * 3) + 2], name: "SCNTWIN")
  end
end
