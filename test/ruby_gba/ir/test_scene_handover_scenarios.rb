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
# A program usually has two rows: one looking while the game is away, and one after it comes
# back. The first is what proves the second means something — a scene that never left would
# pass a row that only looks at the return.
#
# A new thing a scene owns is a new row, and it is tested on both backends by being a row.
class TestSceneHandoverScenarios < Minitest::Test
  include Differential

  # One scenario: its name, the program (the name of a method below that builds it), how many
  # frames the interpreter plays, where to look and what colour must be there.
  #
  # +console_frames+ is how many frames the console plays, for a program that changes screen
  # kind: there the two backends' frame counts cannot be lined up on their own (see
  # Differential#console_frames_for). A row that ends on a tiled screen takes the tiled offset,
  # one frame more than the interpreter; one that ends on the bitmap screen takes two.
  #
  # +broken+ is a Broken, for a scenario a backend gets wrong today and nobody has fixed yet.
  Scenario = Data.define(:name, :program, :frames, :probe, :color, :console_frames, :broken) do
    def initialize(name:, program:, frames:, probe:, color:, console_frames: nil, broken: nil) = super
  end

  # WHAT A BROKEN SCENARIO DOES TODAY, pinned exactly, so the row fails if it gets better — the
  # day it does, the broken: comes out — and also if it goes wrong some other way, which a row
  # that merely expected to fail would hide. +why+ is the fault in words. +interpreter_shows+ is
  # the colour the interpreter shows at the probe instead of the right one (nil when it is
  # right), and +differing+ how many pixels of the console's screen differ from the
  # interpreter's (0 when they agree).
  Broken = Data.define(:why, :interpreter_shows, :differing)

  # What the interpreter shows of a tiled screen it comes back to from the bitmap screen,
  # wherever that tiled screen draws nothing: the bitmap screen's last picture, where the console
  # shows the backdrop.
  BITMAP_SHOWS_THROUGH = "the interpreter still shows the bitmap screen's picture wherever the tiled screen " \
                         "draws nothing, where the console shows the backdrop"

  # The colour a probe reads where nothing is drawn.
  BACKDROP = :backdrop

  # Steps, frame by frame, of the programs below: away on SCENE_AWAY, back on SCENE_BACK, and
  # each looked at once while away (LOOK_AWAY) and once after it is back (LOOK_BACK). The ones
  # that cross to a bitmap screen use the BITMAP_ steps.
  SCENE_AWAY = 4
  SCENE_BACK = 7
  LOOK_AWAY = 6
  LOOK_BACK = 12
  BITMAP_AWAY = 5
  BITMAP_BACK = 9
  LOOK_IN_BITMAP = 7
  LOOK_BACK_FROM_BITMAP = 13
  # ...and the one that then leaves the tiled scene for a bare one on LEAVE_AFTER_BITMAP.
  LEAVE_AFTER_BITMAP = 12
  LOOK_AFTER_LEAVING = 15

  SCENARIOS = [
    Scenario.new(name: :door_open_while_the_room_is_up, program: :door_opened_then_a_bare_scene,
                 frames: SCENE_AWAY, probe: [120, 80], color: :blue),
    Scenario.new(name: :scenery_gone_during_a_bare_scene, program: :door_opened_then_a_bare_scene,
                 frames: LOOK_AWAY, probe: [120, 80], color: BACKDROP),
    Scenario.new(name: :scenery_back_as_declared_after_a_bare_scene, program: :door_opened_then_a_bare_scene,
                 frames: LOOK_BACK, probe: [120, 80], color: :red),
    Scenario.new(name: :second_map_while_the_room_is_up, program: :second_map_then_a_bare_scene,
                 frames: SCENE_AWAY, probe: [0, 0], color: :blue),
    Scenario.new(name: :first_map_back_after_a_bare_scene, program: :second_map_then_a_bare_scene,
                 frames: LOOK_BACK, probe: [0, 0], color: :red),
    Scenario.new(name: :sprite_gone_during_a_bare_scene, program: :sprite_then_a_bare_scene,
                 frames: LOOK_AWAY, probe: [120, 80], color: BACKDROP),
    Scenario.new(name: :sprite_art_back_after_a_bare_scene, program: :sprite_then_a_bare_scene,
                 frames: LOOK_BACK, probe: [120, 80], color: :red),
    Scenario.new(name: :other_scenes_sprite_while_away, program: :sprite_then_another_scenes_sprite,
                 frames: LOOK_AWAY, probe: [120, 80], color: :blue),
    Scenario.new(name: :sprite_art_back_after_another_scene, program: :sprite_then_another_scenes_sprite,
                 frames: LOOK_BACK, probe: [120, 80], color: :red),
    Scenario.new(name: :bitmap_screen_while_away_from_scenery, program: :scenery_then_a_bitmap_screen,
                 frames: LOOK_IN_BITMAP, probe: [0, 0], color: :blue, console_frames: LOOK_IN_BITMAP + 2),
    Scenario.new(name: :scenery_back_after_a_bitmap_screen, program: :scenery_then_a_bitmap_screen,
                 frames: LOOK_BACK_FROM_BITMAP, probe: [0, 0], color: :red,
                 console_frames: LOOK_BACK_FROM_BITMAP + 1),
    Scenario.new(name: :scenery_back_after_a_bitmap_screen_goes_with_its_scene,
                 program: :scenery_across_a_bitmap_screen_then_a_bare_scene,
                 frames: LOOK_AFTER_LEAVING, probe: [0, 0], color: BACKDROP,
                 console_frames: LOOK_AFTER_LEAVING + 1),
    Scenario.new(name: :sprite_art_back_after_a_bitmap_screen, program: :sprite_then_a_bitmap_screen,
                 frames: LOOK_BACK_FROM_BITMAP, probe: [120, 80], color: :red,
                 console_frames: LOOK_BACK_FROM_BITMAP + 1,
                 broken: Broken.new(why: BITMAP_SHOWS_THROUGH, interpreter_shows: nil, differing: 38_144)),
    Scenario.new(name: :painted_tiles_back_with_their_scene, program: :painted_tiles_in_a_scene,
                 frames: 13, probe: [0, 0], color: :white),
    Scenario.new(name: :painted_sprite_back_with_its_scene, program: :painted_sprite_in_a_scene,
                 frames: 13, probe: [0, 0], color: :white),
    Scenario.new(name: :always_up_background_across_a_bitmap_screen, program: :always_up_background,
                 frames: LOOK_BACK_FROM_BITMAP, probe: [0, 0], color: :red,
                 console_frames: LOOK_BACK_FROM_BITMAP + 1,
                 broken: Broken.new(why: "neither backend puts a background every tiled screen shows up " \
                                         "again after a bitmap screen; and #{BITMAP_SHOWS_THROUGH}",
                                    interpreter_shows: :blue, differing: 38_400)),
    Scenario.new(name: :always_up_painted_tiles_across_a_bitmap_screen, program: :always_up_painted_tiles,
                 frames: LOOK_BACK_FROM_BITMAP, probe: [0, 0], color: :white,
                 console_frames: LOOK_BACK_FROM_BITMAP + 1,
                 broken: Broken.new(why: "the background they are on is not put up again after a bitmap " \
                                         "screen, on either backend; and #{BITMAP_SHOWS_THROUGH}",
                                    interpreter_shows: :blue, differing: 38_400)),
    Scenario.new(name: :always_up_painted_sprite_across_a_bitmap_screen, program: :always_up_painted_sprite,
                 frames: LOOK_BACK_FROM_BITMAP, probe: [0, 0], color: :white,
                 console_frames: LOOK_BACK_FROM_BITMAP + 1,
                 broken: Broken.new(why: "the console does not copy the list in again after the bitmap " \
                                         "screen wiped the picture",
                                    interpreter_shows: nil, differing: 1)),
  ].freeze

  SCENARIOS.each_with_index do |scenario, i|
    class_eval <<~RUBY, __FILE__, __LINE__ + 1
      def test_#{scenario.name}
        run_scenario(SCENARIOS[#{i}])
      end
    RUBY
  end

  private def run_scenario(scenario)
    program = send(scenario.program)
    broken = scenario.broken
    shown = Reference.new.run(program, frames: scenario.frames).screen.shown
    x, y = scenario.probe
    assert_equal color_value(broken&.interpreter_shows || scenario.color), shown[(y * SCREEN_W) + x],
                 probe_message(scenario)
    return assert_backends_agree(program, frames: scenario.frames, name: "HANDOVER",
                                          console_frames: scenario.console_frames) unless broken

    oracle, console = backend_pictures(program, frames: scenario.frames, name: "HANDOVER",
                                                console_frames: scenario.console_frames)
    assert_equal broken.differing, mismatched_pixels(oracle, console).size,
                 "#{scenario.name} is broken (#{broken.why}), and the backends now differ somewhere else: " \
                 "if it is fixed, take out its broken:"
  end

  private def probe_message(scenario)
    return "the interpreter shows the wrong colour at #{scenario.probe.inspect}" unless scenario.broken

    "#{scenario.name} is broken (#{scenario.broken.why}), and the interpreter no longer shows what it " \
      "did at #{scenario.probe.inspect}: if it is fixed, take out its broken:"
  end

  private def color_value(color) = color == BACKDROP ? 0 : RubyGBA::Graphics::Color.resolve(color)

  private def built(&block)
    builder = Builder.new
    builder.extend(Words)
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # The steps the programs below share, given to the one Builder each is built with (see
  # #built) and to no other.
  module Words
    # A whole tile of one colour, and a 16x16 picture of one.
    SOLID = Array.new(8) { "#" * 8 }.join("\n").freeze
    BOX = Array.new(16) { "#" * 16 }.join("\n").freeze

    # The red and blue art the programs draw with.
    def red_and_blue_art
      image(:red_art, "#" => :red) { SOLID }
      image(:blue_art, "#" => :blue) { SOLID }
      image(:red_box, "#" => :red) { BOX }
      image(:blue_box, "#" => :blue) { BOX }
    end

    # Two tiles' worth of pixels, all see-through, and the colour list they are drawn from.
    def blank_canvas
      colors :ink, %i[transparent white]
      canvas = list :canvas, capacity: 64, width: :byte
      repeat(64) { canvas.push 0 }
      canvas
    end

    # A game loop counting frames in +tick+ and running scene +first+ while the variable :state
    # is 0 and +second+ while it is 1.
    def two_scene_loop(tick, first, second)
      game_loop do
        tick.add! 1
        case_var(:state) do
          when_val 0, first
          when_val 1, second
        end
      end
    end

    # A tiled scene that hands over to a bitmap screen — all blue — on frame BITMAP_AWAY and takes
    # over again on frame BITMAP_BACK. +tiled+ is what the tiled scene declares; the block runs
    # every frame with the frame count. +third+ names a scene run while :state is 2.
    def across_a_bitmap_screen(tiled: -> {}, third: nil)
      state = var :state, 0
      tick = var :tick, 0
      scene(:tiled_screen) do
        instance_exec(&tiled)
        (tick == BITMAP_AWAY).then { state.set! 1 }
      end
      scene(:bitmap_screen) do
        screen :bitmap
        clear_screen :blue
        (tick == BITMAP_BACK).then { state.set! 0 }
      end
      game_loop do
        tick.add! 1
        yield tick if block_given?
        case_var(:state) do
          when_val 0, :tiled_screen
          when_val 1, :bitmap_screen
          when_val 2, third if third
        end
      end
    end
  end

  # A red room whose door (the cell under the middle of the screen) is opened, in blue, on frame
  # 2; the game walks away to a scene with nothing of its own and comes back. The door is shut
  # again, since the room's scenery goes up as declared.
  private def door_opened_then_a_bare_scene
    built do
      screen :tiled
      red_and_blue_art
      tiles :room, "#" => :red_art, "o" => :blue_art
      state = var :state, 0
      tick = var :tick, 0
      scene(:room) do
        hall = background :hall, tiles: :room, map: Array.new(20) { "#" * 30 }
        (tick == 2).then { hall.set_tile 15, 10, "o" }
        (tick == SCENE_AWAY).then { state.set! 1 }
      end
      scene(:walk) { (tick == SCENE_BACK).then { state.set! 0 } }
      two_scene_loop(tick, :room, :walk)
    end
  end

  # A room with two maps, red and blue, that shows the blue one on frame 2. Away to a bare
  # scene and back, it shows its first map again.
  private def second_map_then_a_bare_scene
    built do
      screen :tiled
      red_and_blue_art
      tiles :room, "r" => :red_art, "b" => :blue_art
      state = var :state, 0
      tick = var :tick, 0
      scene(:room) do
        rooms = background :rooms, tiles: :room, map: { red: Array.new(20) { "r" * 30 },
                                                        blue: Array.new(20) { "b" * 30 } }
        (tick == 2).then { rooms.show_map :blue }
        (tick == SCENE_AWAY).then { state.set! 1 }
      end
      scene(:walk) { (tick == SCENE_BACK).then { state.set! 0 } }
      two_scene_loop(tick, :room, :walk)
    end
  end

  # A red sprite in the middle of a room, away to a scene with nothing and back.
  private def sprite_then_a_bare_scene
    built do
      screen :tiled
      red_and_blue_art
      state = var :state, 0
      tick = var :tick, 0
      scene(:room) do
        sprite :red_box, at: [112, 72]
        (tick == SCENE_AWAY).then { state.set! 1 }
      end
      scene(:walk) { (tick == SCENE_BACK).then { state.set! 0 } }
      two_scene_loop(tick, :room, :walk)
    end
  end

  # A red sprite in one scene and a blue one in another, in the same place: back in the first
  # scene, its own picture is up again rather than the other scene's.
  private def sprite_then_another_scenes_sprite
    built do
      screen :tiled
      red_and_blue_art
      state = var :state, 0
      tick = var :tick, 0
      scene(:red_room) do
        sprite :red_box, at: [112, 72]
        (tick == SCENE_AWAY).then { state.set! 1 }
      end
      scene(:blue_room) do
        sprite :blue_box, at: [112, 72]
        (tick == SCENE_BACK).then { state.set! 0 }
      end
      two_scene_loop(tick, :red_room, :blue_room)
    end
  end

  # A tiled scene's red scenery, away to the bitmap screen — which uses the video memory the
  # scenery was in — and back.
  private def scenery_then_a_bitmap_screen
    built do
      screen :tiled
      red_and_blue_art
      tiles :set, "#" => :red_art
      across_a_bitmap_screen(tiled: -> { background :field, tiles: :set, map: Array.new(20) { "#" * 30 } })
    end
  end

  # The same, and then on to a tiled scene with nothing of its own: the scenery that came back
  # after the bitmap screen goes again with its scene.
  private def scenery_across_a_bitmap_screen_then_a_bare_scene
    built do
      screen :tiled
      red_and_blue_art
      tiles :set, "#" => :red_art
      scene(:walk) { nil }
      across_a_bitmap_screen(tiled: -> { background :field, tiles: :set, map: Array.new(20) { "#" * 30 } },
                             third: :walk) do |tick|
        (tick == LEAVE_AFTER_BITMAP).then { set! :state, 2 }
      end
    end
  end

  # A tiled scene's red sprite, away to the bitmap screen and back.
  private def sprite_then_a_bitmap_screen
    built do
      screen :tiled
      red_and_blue_art
      across_a_bitmap_screen(tiled: -> { sprite :red_box, at: [112, 72] })
    end
  end

  # Tiles a scene paints from a list: the list is written while the scene is away, without a
  # word, and the scene shows the list as it is when it takes over again on frame 9.
  private def painted_tiles_in_a_scene
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
      two_scene_loop(tick, :talking, :walking)
    end
  end

  # The same for a sprite's painted picture.
  private def painted_sprite_in_a_scene
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
      two_scene_loop(tick, :talking, :walking)
    end
  end

  # A red background every tiled screen shows, away to the bitmap screen and back.
  private def always_up_background
    built do
      screen :tiled
      red_and_blue_art
      tiles :set, "#" => :red_art
      background :field, tiles: :set, map: Array.new(20) { "#" * 30 }
      across_a_bitmap_screen
    end
  end

  # Tiles painted from a list on a background every tiled screen shows: painted on frame 2, then
  # away to the bitmap screen and back.
  private def always_up_painted_tiles
    built do
      screen :tiled
      canvas = blank_canvas
      box = tiles :box, from: canvas, count: 2, colors: :ink
      background :box, tiles: :box, map: [[1, 2]]
      across_a_bitmap_screen { |tick| (tick == 2).then { canvas[0] = 0x01; box.changed } }
    end
  end

  # The same for a sprite's painted picture.
  private def always_up_painted_sprite
    built do
      screen :tiled
      canvas = blank_canvas
      tag = image :tag, from: canvas, width: 16, height: 8, colors: :ink
      sprite :tag, at: [0, 0]
      across_a_bitmap_screen { |tick| (tick == 2).then { canvas[0] = 0x01; tag.changed } }
    end
  end
end
