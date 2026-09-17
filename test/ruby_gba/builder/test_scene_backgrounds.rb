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

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # Two scenes that take turns, +per_scene+ full-screen scrolling backgrounds in each.
  # The last one declared in a scene is the one in front, so it is the colour that shows.
  def two_scenes(per_scene)
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

  def shown(prog, frames) = Reference.new.run(prog, frames: frames).screen.pixel(*MIDDLE)

  def on_console(prog, name, frames)
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
  def a_backdrop_and_two_scenes(per_scene)
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
  def uneven_over_a_backdrop(first, second)
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
  def uneven_scenes(first, second)
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

  # Every pixel of the screen, not the two sampled above. A layer left switched on, or one
  # numbered differently by the two backends, shows up here and nowhere else — the pixels
  # picked by hand are the ones somebody already thought to look at.
  def test_the_two_backends_draw_the_same_screen_after_the_scene_changes
    assert_backends_agree(two_scenes(4), frames: SWITCH_AT + 4)
    assert_backends_agree(uneven_scenes(3, 1), frames: SWITCH_AT + 4)
    assert_backends_agree(a_backdrop_and_two_scenes(3), frames: SWITCH_AT + 4)
  end
end
