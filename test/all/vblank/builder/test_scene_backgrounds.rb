# frozen_string_literal: true

require "test_helper"
require "differential"
require "many_tiles"

# The games these tests play, shared with the Advance's cartridge's tests
# (test/lowering/gba/vblank/builder/test_scene_backgrounds_cartridge.rb).
module SceneBackgroundGames
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

  # A SCENE THAT COMES BACK AFTER A BARE ONE PUTS ITS SCENERY UP AS DECLARED. A cell it had
  # changed is back as drawn. The console used to keep the scene marked as still up across a
  # scene with no scenery of its own, so it skipped putting it up and kept the changed cell.
  private def a_door_opened_then_a_bare_scene_then_back
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      tiles :room, "#" => :red_art, "o" => :blue_art
      state = var :state, 0
      tick = var :tick, 0
      scene(:room) do
        hall = background :hall, tiles: :room, map: Array.new(20) { "#" * 30 }
        (tick == 2).then { hall.set_tile 15, 10, "o" } # the cell under the middle of the screen
        (tick == SWITCH_AT).then { state.set! 1 }
      end
      scene(:walk) { (tick == SWITCH_AT + 3).then { state.set! 0 } }
      game_loop do
        tick.add! 1
        case_var(:state) do
          when_val 0, :room
          when_val 1, :walk
        end
      end
    end
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

  # ...BUT ONLY WHILE THE SCENE STAYS UP. Leave it and come back and the scene is put up as
  # it was declared, the changed cell with it, the same promise show_map makes about a map
  # chosen again. A game that remembers an opened door opens it again on the way in. The
  # console did that already, because putting a scene up sends its map; the interpreter
  # kept painting its own changed copy, so a game's tests saw the door open and the
  # cartridge showed it shut.
  private def leaving_and_coming_back
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      tiles :set, "#" => :red_art, "." => :blue_art
      map = Array.new(20) { "#" * 30 }
      tick = var :tick, 0
      state = var :state, 0
      scene(:play) do
        room = background :room, tiles: :set, map: map
        (tick == 2).then { room.set_tile 0, 0, "." }
      end
      scene(:away) { background :elsewhere, tiles: :set, map: map }
      game_loop do
        tick.add! 1
        (tick == 4).then { state.set! 1 } # away...
        (tick == 7).then { state.set! 0 } # ...and back
        case_var(:state) do
          when_val 0, :play
          when_val 1, :away
        end
      end
    end
  end

  # THE SAME FOR A MAP CHOSEN WITH show_map: coming back shows the first map declared, and
  # the background says so. The half that went wrong on the console was the second one —
  # it put the first map up but still remembered choosing the other, so choosing that one
  # again was taken as already done and the picture never changed.
  private def choosing_a_map_and_coming_back
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:red_art, "#" => :red) { tile }
      image(:blue_art, "#" => :blue) { tile }
      tiles :set, "#" => :red_art, "." => :blue_art
      tick = var :tick, 0
      state = var :state, 0
      seen = var :seen, 0
      scene(:play) do
        rooms = background :rooms, tiles: :set,
                                   map: { hall: Array.new(20) { "#" * 30 }, cave: Array.new(20) { "." * 30 } }
        (tick == 2).then { rooms.show_map :cave }
        (tick == 12).then { rooms.show_map :cave } # the same map again, after coming back
        seen.set! rooms.showing
      end
      scene(:away) { background :elsewhere, tiles: :set, map: Array.new(20) { "#" * 30 } }
      game_loop do
        tick.add! 1
        (tick == 4).then { state.set! 1 } # away...
        (tick == 7).then { state.set! 0 } # ...and back
        case_var(:state) do
          when_val 0, :play
          when_val 1, :away
        end
      end
    end
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
end

# A SCENE OWNS THE BACKGROUNDS DECLARED INSIDE IT, the way it already owns the sprites
# and the HUD text declared there: they are on screen while that scene is the active
# state and not otherwise.
#
# That is what makes a game with many rooms writable — each room's scenery declared where
# it belongs — and it is what decides how many background layers a game may have at all.
# The console holds four scrolling layers AT ONCE, so what has to fit is one scene's
# worth, not the whole game's, exactly as the 32K of sprite pictures already works.
#
# What the Advance's cartridge does with each of these, read in the emulator, is in
# test/lowering/gba/vblank/builder/test_scene_backgrounds_cartridge.rb.
class TestSceneBackgrounds < Minitest::Test
  include Differential
  include SceneBackgroundGames

  private def shown(prog, frames) = game_player.run(prog, frames: frames).screen.pixel(*MIDDLE)

  def test_a_scene_back_after_a_bare_one_puts_its_scenery_up_as_declared
    assert_equal BLUE, shown(a_door_opened_then_a_bare_scene_then_back, SWITCH_AT), "the door was opened"
    assert_equal RED, shown(a_door_opened_then_a_bare_scene_then_back, SWITCH_AT + 8), "and is shut again"
  end

  # ...and one more in each scene is five at a time, which is refused — naming the scene,
  # because "this game declares five" would send the author counting the whole program.
  def test_one_too_many_in_a_scene_is_refused_and_names_the_scene
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(a_backdrop_and_two_scenes(4)) }

    assert_includes error.message, "at one time"
    assert_includes error.message, ":one", "the message does not say which scene ran out"
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

  # A SCENE'S BACKGROUND GOES AWAY WITH THE SCENE. Asserted on its own and at one
  # background per scene, because it is the plainest statement of the rule the count above
  # depends on: if the first scene's scenery were still being drawn, its layers would
  # still be spoken for and the count could never be per scene.
  def test_the_first_scenes_background_stops_being_drawn_when_the_second_takes_over
    assert_equal RED, shown(two_scenes(1), SWITCH_AT)
    assert_equal BLUE, shown(two_scenes(1), SWITCH_AT + 4)
  end

  def test_a_background_declared_inside_a_scene_scrolls
    at_top_level = game_player.run(scrolling_program(in_a_scene: false), frames: SCROLLED_FOR).screen
    in_a_scene = game_player.run(scrolling_program(in_a_scene: true), frames: SCROLLED_FOR).screen

    assert_equal top_row { |x| at_top_level.pixel(x, 0) }, top_row { |x| in_a_scene.pixel(x, 0) },
                 "the scene's background did not scroll the way the same one at the top level did"
  end

  def test_a_cell_changed_in_a_scenes_background_stays_changed
    seen = (2..8).map { |f| game_player.run(changing_program, frames: f).screen.pixel(0, 0) }

    assert_equal [BLUE], seen.uniq, "the changed cell was put back by the next frame"
  end

  def test_coming_back_to_a_scene_puts_its_background_up_as_declared
    screen = game_player.run(leaving_and_coming_back, frames: 10).screen

    assert_equal RED, screen.pixel(0, 0), "the cell changed before leaving was still changed on return"
  end

  def test_coming_back_shows_the_first_map_and_can_choose_again
    before = game_player.run(choosing_a_map_and_coming_back, frames: 4)
    assert_equal 1, before[:seen], "the other map was never chosen, so nothing below means anything"

    back = game_player.run(choosing_a_map_and_coming_back, frames: 10)
    assert_equal RED, back.screen.pixel(0, 0), "the map chosen before leaving was still showing"
    assert_equal 0, back[:seen], "the background still said the other map was showing"

    again = game_player.run(choosing_a_map_and_coming_back, frames: 15)
    assert_equal BLUE, again.screen.pixel(0, 0), "choosing the map again after coming back did nothing"
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
    skip_on_snes "put up every pass, it shows nothing in the columns past its map's right edge, where the " \
                 "interpreter shows the map scrolled round"
    assert_backends_agree(in_a_plain_routine, frames: SCROLLED_FOR)
  end

  def test_a_scenes_background_comes_back_after_a_bitmap_screen
    assert_equal RED, game_player.run(there_and_back, frames: 9).screen.pixel(0, 0),
                 "the scenery never came back after the other kind of screen wiped it"
  end

  # ...and the same for a scene's background that MOVES and one whose cells CHANGE. Both
  # halves above compare a backend against itself — the scene's picture against the top
  # level's on the same backend — which a wrong-but-consistent answer would satisfy. This
  # is the half that cannot: the two backends reached the changed cell by different routes
  # and disagreed about it until now.
  def test_the_two_backends_draw_the_same_moving_and_changing_scene
    assert_backends_agree(scrolling_program(in_a_scene: true), frames: SCROLLED_FOR)
    assert_backends_agree(leaving_and_coming_back, frames: 10)
    assert_backends_agree(choosing_a_map_and_coming_back, frames: 10)
    assert_backends_agree(choosing_a_map_and_coming_back, frames: 15)
    assert_backends_agree(changing_program, frames: SCROLLED_FOR)
  end

  def test_the_two_backends_agree_about_a_scenes_drifting_scenery
    assert_backends_agree(a_drifting_title_and_a_still_game, frames: 6)
  end

  # EACH SCENE'S TILES ARE ITS OWN TO COUNT: two scenes of 300 different tiles each, with a status
  # bar every screen shows, are more tiles than the Color holds at once, and each screen
  # alone is fewer. The scenes take turns twice, so the first comes back after the second's tiles
  # went in where its own had been.
  private def two_scenes_of_many_tiles_each
    test = self
    program do
      screen :tiled
      first = ManyTiles.declare(self, :first_tiles, 300, :red)
      second = ManyTiles.declare(self, :second_tiles, 300, :blue, from: 300)
      under = ManyTiles.declare(self, :shared_tiles, 20, :green, from: 600)
      status_bar :border, tiles: :shared_tiles, map: under, top: 120
      scene(:one) { background :one, tiles: :first_tiles, map: first }
      scene(:two) { background :two, tiles: :second_tiles, map: second }
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick == test.class::TILES_SWITCH_AT).then { state.set! 1 }
        (tick == test.class::TILES_SWITCH_AT * 2).then { state.set! 0 }
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
  end

  TILES_SWITCH_AT = 4

  def test_scenes_whose_tiles_together_are_more_than_the_console_holds_each_show_their_own
    prog = two_scenes_of_many_tiles_each
    played = ->(frames) { game_player.run(prog, frames: frames).screen }

    assert_equal RED, played.call(2).pixel(8, 0), "the first scene's second tile"
    assert_equal BLUE, played.call(TILES_SWITCH_AT + 3).pixel(8, 0), "the second scene's"
    assert_backends_agree(prog, frames: [2, TILES_SWITCH_AT + 3, (TILES_SWITCH_AT * 2) + 3], name: "SCNTILES")
  end

  # EACH SCENE'S COLOURS ARE ITS OWN TO COUNT too: two scenes each drawing from six lists of four
  # colours of their own, twelve between them, which is more than the eight a Game Boy Color holds
  # at once. A fade is in force from before the second scene arrives until after, so its colours
  # arrive faded, and the first scene comes back after the second's colours went in where its own
  # had been.
  COLORS_SWITCH_AT = 4

  # Six lists of four colours, place 0 see-through, numbered from +first+: no two alike, black in each.
  private def six_lists(first)
    (first...(first + 6)).map do |n|
      [:transparent, VBlank::Graphics::Color.rgb(31, 31 - n, 2 * n), VBlank::Graphics::Color.rgb(2 * n, 31, 8),
       VBlank::Graphics::Color.rgb(n, n, 31), 0]
    end
  end

  # +dusk+, a list of colours, is one the first scene's first list is drawn with from the first
  # frame, said once.
  private def two_scenes_of_six_lists_each(dusk: nil)
    lists = { one: six_lists(0), two: six_lists(6) }
    switch = COLORS_SWITCH_AT
    program do
      screen :tiled
      row = lists.map { |name, colored| ManyTiles.declare_listed(self, :"#{name}_set", colored) }.first
      colors :dusk, dusk if dusk
      state = var :state, 0
      tick = var :tick, 0
      dim = var :dim, 0
      scene(:one) do
        first = background :one, tiles: :one_set, map: Array.new(4) { row }
        (tick == 1).then { first.draw_with({ one_set_list0: :dusk }) } if dusk
      end
      scene(:two) { background :two, tiles: :two_set, map: Array.new(4) { row } }
      game_loop do
        tick.add! 1
        (tick == switch - 1).then { dim.set! 50 }
        (tick == switch + 3).then { dim.set! 0 }
        (tick == switch).then { state.set! 1 }
        (tick == switch * 3).then { state.set! 0 }
        fade :black, dim
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
  end

  def test_scenes_whose_colours_together_are_more_than_the_console_holds_each_show_their_own
    prog = two_scenes_of_six_lists_each
    played = ->(frames) { game_player.run(prog, frames: frames).screen }
    one, two = [0, 6].map { |n| VBlank::Graphics::Color.rgb(31, 31 - n, 2 * n) }

    assert_equal one, played.call(2).pixel(0, 0), "the first scene's first list"
    assert_equal two, played.call((COLORS_SWITCH_AT * 2) + 1).pixel(0, 0), "the second scene's"
    assert_equal one, played.call((COLORS_SWITCH_AT * 3) + 3).pixel(0, 0), "the first scene's again"
    assert_backends_agree(prog, frames: [2, COLORS_SWITCH_AT + 2, (COLORS_SWITCH_AT * 3) + 3], name: "SCNCOLORS")
  end

  # A scene's background drawn with another list keeps it when the scene comes back, said once,
  # though the scene's own colours came in again with it.
  def test_a_scene_back_with_its_own_colours_keeps_the_list_it_was_drawn_with
    dusk = [:transparent, VBlank::Graphics::Color.rgb(3, 3, 20), VBlank::Graphics::Color.rgb(20, 3, 3),
            VBlank::Graphics::Color.rgb(3, 20, 3), VBlank::Graphics::Color.rgb(31, 31, 31)]
    prog = two_scenes_of_six_lists_each(dusk: dusk)

    assert_equal dusk[1], game_player.run(prog, frames: (COLORS_SWITCH_AT * 3) + 3).screen.pixel(0, 0)
  end

  # --- one background name in two scenes ---

  # ONE NAME, A DECLARATION IN EACH SCENE, the way a game writes its levels: each level is a
  # scene with a :world of its own, drawn from the same tiles in a different map, the second
  # with a tile of its own as well. Each scene shows its own declaration, the game changes a
  # cell of the second level's from the game loop, and the first level comes back as declared.
  NAME_SWITCH_AT = 4

  private def two_levels
    test = self
    program do
      screen :tiled
      image(:floor, "#" => :red) { SOLID_TILE }
      image(:wall, "#" => :blue) { SOLID_TILE }
      image(:door, "#" => :green) { SOLID_TILE }
      tiles :world_tiles, "#" => :floor, "w" => :wall
      tiles :world_and_door, "#" => :floor, "w" => :wall, "d" => :door
      state = var :state, 0
      tick = var :tick, 0
      door_at = var :door_at, 1
      scene(:level_one) { background :world, tiles: :world_tiles, map: Array.new(20) { "#w" * 15 } }
      scene(:level_two) do
        second = background :world, tiles: :world_and_door, map: Array.new(20) { "w#" * 15 }
        (tick == test.class::NAME_SWITCH_AT + 2).then { second.set_tile door_at, 0, "d" }
      end
      game_loop do
        tick.add! 1
        (tick == test.class::NAME_SWITCH_AT).then { state.set! 1 }
        (tick == test.class::NAME_SWITCH_AT * 2).then { state.set! 0 }
        case_var(:state) do
          when_val 0, :level_one
          when_val 1, :level_two
        end
      end
    end
  end

  def test_a_name_declared_in_two_scenes_shows_each_scenes_own_map
    prog = two_levels
    played = ->(frames) { game_player.run(prog, frames: frames).screen }

    assert_equal [RED, BLUE], [played.call(2).pixel(0, 0), played.call(2).pixel(8, 0)], "the first level's map"
    assert_equal [BLUE, RED], [played.call(NAME_SWITCH_AT + 1).pixel(0, 0), played.call(NAME_SWITCH_AT + 1).pixel(8, 0)],
                 "the second level's map"
    assert_equal VBlank::Graphics::Color.resolve(:green), played.call(NAME_SWITCH_AT + 3).pixel(8, 0), "its door"
    assert_backends_agree(prog, frames: [2, NAME_SWITCH_AT + 1, NAME_SWITCH_AT + 3, (NAME_SWITCH_AT * 2) + 3],
                          name: "SCNLEVEL")
  end

  # ...and the same from the FIRST scene to declare the name, which every line naming the
  # background must reach while it is up, not the last declaration: the first level has two
  # maps of its own and the second one, and the game hands the first level its second map and
  # then changes a cell of it. Neither may read the second level's maps.
  private def two_levels_changed_in_the_first
    test = self
    program do
      screen :tiled
      image(:floor, "#" => :red) { SOLID_TILE }
      image(:wall, "#" => :blue) { SOLID_TILE }
      image(:door, "#" => :green) { SOLID_TILE }
      tiles :world_and_door, "#" => :floor, "w" => :wall, "d" => :door
      tiles :world_tiles, "#" => :floor, "w" => :wall
      state = var :state, 0
      tick = var :tick, 0
      room = var :room, 0
      scene(:level_one) do
        first = background :world, tiles: :world_and_door,
                                   map: { hall: Array.new(20) { "#w" * 15 }, cellar: Array.new(20) { "ww" * 15 } }
        first.show_map room
        (tick == 2).then { room.set! 1 }
        (tick == 4).then { first.set_tile 0, 0, "d" } # after the cellar is in, which writes every cell
      end
      scene(:level_two) do
        background :world, tiles: :world_tiles, map: { attic: Array.new(20) { "##" * 15 }, roof: Array.new(20) { "w#" * 15 } }
      end
      game_loop do
        tick.add! 1
        (tick == test.class::NAME_SWITCH_AT * 2).then { state.set! 1 }
        case_var(:state) do
          when_val 0, :level_one
          when_val 1, :level_two
        end
      end
    end
  end

  # A ROUTINE BOTH LEVELS CALL opens the second level's door, a tile only the second level's
  # :world has. Called while the first level is up, there is no such tile to put in its cells,
  # and nothing changes; called while the second is up, the door opens.
  private def a_door_only_one_level_has
    test = self
    program do
      screen :tiled
      image(:floor, "#" => :red) { SOLID_TILE }
      image(:wall, "#" => :blue) { SOLID_TILE }
      image(:door, "#" => :green) { SOLID_TILE }
      tiles :world_tiles, "#" => :floor, "w" => :wall
      tiles :world_and_door, "#" => :floor, "w" => :wall, "d" => :door
      state = var :state, 0
      tick = var :tick, 0
      second = nil
      scene(:level_one) do
        background :world, tiles: :world_tiles, map: Array.new(20) { "#w" * 15 }
        (tick == 3).then { call :open_door }
      end
      scene(:level_two) do
        second = background :world, tiles: :world_and_door, map: Array.new(20) { "w#" * 15 }
        (tick == test.class::NAME_SWITCH_AT + 2).then { call :open_door }
      end
      func(:open_door) { second.set_tile 0, 0, "d" }
      game_loop do
        tick.add! 1
        (tick == test.class::NAME_SWITCH_AT).then { state.set! 1 }
        case_var(:state) do
          when_val 0, :level_one
          when_val 1, :level_two
        end
      end
    end
  end

  def test_a_tile_only_another_scenes_declaration_has_changes_nothing
    prog = a_door_only_one_level_has
    played = ->(frames) { game_player.run(prog, frames: frames).screen }

    assert_equal RED, played.call(3).pixel(0, 0), "the first level, no door"
    assert_equal GREEN, played.call(NAME_SWITCH_AT + 3).pixel(0, 0), "the second level's door"
    assert_backends_agree(prog, frames: [3, NAME_SWITCH_AT + 3], name: "SCNDOOR")
  end

  def test_a_name_declared_in_two_scenes_is_changed_in_the_first_as_declared_there
    prog = two_levels_changed_in_the_first
    played = ->(frames) { game_player.run(prog, frames: frames).screen }

    assert_equal [GREEN, BLUE], [played.call(5).pixel(0, 0), played.call(5).pixel(8, 0)],
                 "the first level's cellar, with its door"
    assert_equal RED, played.call((NAME_SWITCH_AT * 2) + 2).pixel(8, 0), "the second level's attic"
    assert_backends_agree(prog, frames: [3, 5, (NAME_SWITCH_AT * 2) + 2], name: "SCNFIRST")
  end

  # A SPRITE EVERY SCREEN SHOWS, OVER A SCENE WITH NO BACKGROUND OF ITS OWN: the hall takes the
  # scenery down as it goes, and the sprite stays where it is over the backdrop, then over the
  # hall again as it comes back.
  private def a_sprite_over_a_scene_with_no_scenery
    program do
      screen :tiled
      image(:wall_art, "#" => :blue) { SOLID_TILE }
      image(:hero_art, "#" => :red) { SOLID_TILE }
      tiles :walls, "#" => :wall_art
      sprite :hero_art, at: [16, 16]
      tick = var :tick, 0
      var :state, 0
      scene(:hall) { background :room, tiles: :walls, map: Array.new(5) { "#" * 10 } }
      scene(:away) { nil }
      game_loop do
        tick.add! 1
        (tick == 5).then { set! :state, 1 }
        (tick == 7).then { set! :state, 0 }
        case_var(:state) do
          when_val 0, :hall
          when_val 1, :away
        end
      end
    end
  end

  def test_a_sprite_shows_over_a_scene_with_no_scenery_of_its_own
    prog = a_sprite_over_a_scene_with_no_scenery
    played = ->(frames) { game_player.run(prog, frames: frames).screen }

    assert_equal RED, played.call(5).pixel(20, 20), "the sprite, on the frame the hall comes down"
    assert_equal RED, played.call(6).pixel(20, 20), "the sprite, over nothing"
    refute_equal BLUE, played.call(6).pixel(60, 20), "the hall is down"
    assert_equal BLUE, played.call(9).pixel(60, 20), "and up again"
    assert_backends_agree(prog, frames: [5, 6, 9], name: "SCNAWAY")
  end
end
