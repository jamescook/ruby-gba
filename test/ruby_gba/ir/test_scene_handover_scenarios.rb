# frozen_string_literal: true

require "test_helper"
require "differential"

# WHAT A SCENE PUTS UP AS IT TAKES OVER, asked the same way of both backends.
#
# A scene owns its scenery, its sprites' pictures and the tiles it paints, and they go up as
# declared each time it takes over (see IR::SceneHandover). The interpreter and the console do
# that each in their own way, and the way they have drifted apart before is a test written for
# one of them and never for the other. So every scenario here is one row, and every row is run
# both ways: the interpreter's picture is checked at one point against the colour the scenario
# says it must be — so both backends cannot agree on something wrong — and then the console's
# whole screen is compared with the interpreter's, pixel for pixel.
#
# A new thing a scene owns is a new row, and it is tested on both backends by being a row.
class TestSceneHandoverScenarios < Minitest::Test
  include Differential

  # One scenario: the program (the name of a method below that builds it), how many frames the
  # interpreter plays, where to look and what colour must be there, and — for a program that
  # changes screen kind, where the two backends' frame counts cannot be lined up on their own —
  # how many frames the console plays.
  #
  # +broken+ says what is wrong today, for a scenario that a backend gets wrong and nobody has
  # fixed yet. Such a row is still run, and it has to FAIL: the day it passes, the test says
  # so, and the row is moved in with the others.
  Scenario = Data.define(:program, :frames, :probe, :color, :console_frames, :broken) do
    def initialize(program:, frames:, probe:, color:, console_frames: nil, broken: nil) = super
  end

  SCENARIOS = [
    Scenario.new(program: :scenery_back_after_a_bare_scene, frames: 12, probe: [120, 80], color: :red),
    Scenario.new(program: :first_map_back_after_a_bare_scene, frames: 12, probe: [0, 0], color: :red),
    Scenario.new(program: :sprite_art_back_after_another_scene, frames: 12, probe: [120, 80], color: :red),
    Scenario.new(program: :scenery_back_after_a_bitmap_screen, frames: 9, probe: [0, 0], color: :red,
                 console_frames: 10),
    Scenario.new(program: :painted_tiles_back_with_their_scene, frames: 13, probe: [0, 0], color: :white),
    Scenario.new(program: :painted_sprite_back_with_its_scene, frames: 13, probe: [0, 0], color: :white),
    Scenario.new(program: :painted_tiles_always_up_across_a_bitmap_screen, frames: 13, probe: [0, 0],
                 color: :white, console_frames: 14,
                 broken: "neither backend copies the list in again after the bitmap screen wiped the tiles"),
    Scenario.new(program: :painted_sprite_always_up_across_a_bitmap_screen, frames: 13, probe: [0, 0],
                 color: :white, console_frames: 14,
                 broken: "the console does not copy the list in again after the bitmap screen wiped the picture"),
  ].freeze

  SCENARIOS.each do |scenario|
    class_eval <<~RUBY, __FILE__, __LINE__ + 1
      def test_#{scenario.program}
        run_scenario(SCENARIOS.find { |row| row.program == :#{scenario.program} })
      end
    RUBY
  end

  private def run_scenario(scenario)
    return assert_scenario_holds(scenario) unless scenario.broken

    assert_raises(Minitest::Assertion, "#{scenario.program} passes now, so it is no longer broken: " \
                                       "take out its broken: and keep it as a row like any other") do
      assert_scenario_holds(scenario)
    end
  end

  private def assert_scenario_holds(scenario)
    program = send(scenario.program)
    shown = Reference.new.run(program, frames: scenario.frames).screen.shown
    x, y = scenario.probe
    assert_equal RubyGBA::Graphics::Color.resolve(scenario.color), shown[(y * SCREEN_W) + x],
                 "the interpreter shows the wrong colour at #{scenario.probe.inspect}"
    assert_backends_agree(program, frames: scenario.frames, name: "HANDOVER",
                                   console_frames: scenario.console_frames)
  end

  private def built(&block)
    builder = Builder.new
    builder.extend(Words)
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # A whole tile of one colour.
  SOLID = Array.new(8) { "#" * 8 }.join("\n")

  # A room whose door (the cell under the middle of the screen) is opened on frame 2; the game
  # walks away to a scene with nothing of its own on frame 4 and comes back on frame 7. The door
  # is shut again, since the room's scenery goes up as declared.
  private def scenery_back_after_a_bare_scene
    built do
      screen :tiled
      image(:red_art, "#" => :red) { SOLID }
      image(:blue_art, "#" => :blue) { SOLID }
      tiles :room, "#" => :red_art, "o" => :blue_art
      state = var :state, 0
      tick = var :tick, 0
      scene(:room) do
        hall = background :hall, tiles: :room, map: Array.new(20) { "#" * 30 }
        (tick == 2).then { hall.set_tile 15, 10, "o" }
        (tick == 4).then { state.set! 1 }
      end
      scene(:walk) { (tick == 7).then { state.set! 0 } }
      game_loop do
        tick.add! 1
        case_var(:state) do
          when_val 0, :room
          when_val 1, :walk
        end
      end
    end
  end

  # A room with two maps, red and blue, that shows the blue one on frame 2. Away to a bare
  # scene on frame 4 and back on frame 7, it shows its first map again.
  private def first_map_back_after_a_bare_scene
    built do
      screen :tiled
      image(:red_art, "#" => :red) { SOLID }
      image(:blue_art, "#" => :blue) { SOLID }
      tiles :room, "r" => :red_art, "b" => :blue_art
      state = var :state, 0
      tick = var :tick, 0
      scene(:room) do
        rooms = background :rooms, tiles: :room, map: { red: Array.new(20) { "r" * 30 },
                                                        blue: Array.new(20) { "b" * 30 } }
        (tick == 2).then { rooms.show_map :blue }
        (tick == 4).then { state.set! 1 }
      end
      scene(:walk) { (tick == 7).then { state.set! 0 } }
      two_scene_loop(tick, state, :room, :walk)
    end
  end

  # A red sprite in one scene and a blue one in another, in the same place: back in the first
  # scene on frame 7, its own picture is up again rather than the other scene's.
  private def sprite_art_back_after_another_scene
    built do
      screen :tiled
      image(:red_box, "#" => :red) { Array.new(16) { "#" * 16 }.join("\n") }
      image(:blue_box, "#" => :blue) { Array.new(16) { "#" * 16 }.join("\n") }
      state = var :state, 0
      tick = var :tick, 0
      scene(:red_room) do
        sprite :red_box, at: [112, 72]
        (tick == 4).then { state.set! 1 }
      end
      scene(:blue_room) do
        sprite :blue_box, at: [112, 72]
        (tick == 7).then { state.set! 0 }
      end
      two_scene_loop(tick, state, :red_room, :blue_room)
    end
  end

  # A tiled scene's scenery, away to a bitmap screen on frame 3 — which wipes the video memory
  # the scenery was in — and back on frame 6.
  private def scenery_back_after_a_bitmap_screen
    built do
      image(:red_art, "#" => :red) { SOLID }
      tiles :set, "#" => :red_art
      screen :tiled
      scene(:field) { background :field, tiles: :set, map: Array.new(20) { "#" * 30 } }
      scene(:title) do
        screen :bitmap
        clear_screen :black
      end
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick == 3).then { state.set! 1 }
        (tick == 6).then { state.set! 0 }
        case_var(:state) do
          when_val 0, :field
          when_val 1, :title
        end
      end
    end
  end

  # Tiles a scene paints from a list: the list is written while the scene is away, without a
  # word, and the scene shows the list as it is when it takes over again on frame 9.
  private def painted_tiles_back_with_their_scene
    built do
      screen :tiled
      canvas = blank_canvas
      state = var :state, 0
      tick = var :tick, 0
      scene(:talking) do
        tiles :box, from: canvas, count: 2, colors: :ink
        background :box, tiles: :box, map: [[1, 2]]
        (tick == 5).then { state.set! 1 }
      end
      scene(:walking) do
        (tick == 7).then { canvas[0] = 0x01 } # the top-left pixel, in white
        (tick == 9).then { state.set! 0 }
      end
      two_scene_loop(tick, state, :talking, :walking)
    end
  end

  # The same for a sprite's painted picture.
  private def painted_sprite_back_with_its_scene
    built do
      screen :tiled
      canvas = blank_canvas
      state = var :state, 0
      tick = var :tick, 0
      scene(:talking) do
        image :tag, from: canvas, width: 16, height: 8, colors: :ink
        sprite :tag, at: [0, 0]
        (tick == 5).then { state.set! 1 }
      end
      scene(:walking) do
        (tick == 7).then { canvas[0] = 0x01 }
        (tick == 9).then { state.set! 0 }
      end
      two_scene_loop(tick, state, :talking, :walking)
    end
  end

  # Tiles painted from a list on a background that every tiled screen shows: painted on frame
  # 2, away to a bitmap screen on frame 5, which wipes the video memory, and back on frame 9.
  private def painted_tiles_always_up_across_a_bitmap_screen
    built do
      screen :tiled
      canvas = blank_canvas
      box = tiles :box, from: canvas, count: 2, colors: :ink
      background :box, tiles: :box, map: [[1, 2]]
      across_a_bitmap_screen { |tick| (tick == 2).then { canvas[0] = 0x01; box.changed } }
    end
  end

  # The same for a sprite's painted picture.
  private def painted_sprite_always_up_across_a_bitmap_screen
    built do
      screen :tiled
      canvas = blank_canvas
      tag = image :tag, from: canvas, width: 16, height: 8, colors: :ink
      sprite :tag, at: [0, 0]
      across_a_bitmap_screen { |tick| (tick == 2).then { canvas[0] = 0x01; tag.changed } }
    end
  end
end

# The words the scenarios above share, given to the one Builder each scenario is built with
# (see #built) and to no other.
module TestSceneHandoverScenarios::Words
  # Two tiles' worth of pixels, all see-through, and the colour list they are drawn from.
  def blank_canvas
    colors :ink, %i[transparent white]
    canvas = list :canvas, capacity: 64, width: :byte
    repeat(64) { canvas.push 0 }
    canvas
  end

  # A game loop counting frames in +tick+ and running scene +first+ while +state+ is 0 and
  # +second+ while it is 1.
  def two_scene_loop(tick, state, first, second)
    game_loop do
      tick.add! 1
      case_var(state.name) do
        when_val 0, first
        when_val 1, second
      end
    end
  end

  # A tiled scene that hands over to a bitmap screen on frame 5 and takes over again on frame
  # 9; the block runs every frame with the frame count.
  def across_a_bitmap_screen
    state = var :state, 0
    tick = var :tick, 0
    scene(:tiled_screen) { (tick == 5).then { state.set! 1 } }
    scene(:bitmap_screen) do
      screen :bitmap
      clear_screen :black
      (tick == 9).then { state.set! 0 }
    end
    game_loop do
      tick.add! 1
      yield tick
      case_var(:state) do
        when_val 0, :tiled_screen
        when_val 1, :bitmap_screen
      end
    end
  end
end
