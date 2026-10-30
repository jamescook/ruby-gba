# frozen_string_literal: true

require "test_helper"
require "differential"

# The rows of test_scene_handover_scenarios.rb whose games turn a whole background, which a Game
# Boy Color's hardware cannot do, so they play on the Advance's runs alone. Each row is run the
# same way as there: the interpreter's picture is checked at one point against the colour the
# row says it must be, and then the console's whole screen is compared with the interpreter's.
class TestSceneHandoverScenariosOnTheAdvance < Minitest::Test
  include Differential

  # One scenario: its name, the program (the name of a method below that builds it), how many
  # frames the interpreter plays, where to look and what colour must be there, and how many
  # frames the console plays (see Differential#console_frames_for). A row that ends on a tiled
  # screen takes the tiled offset, one frame more than the interpreter.
  Scenario = Data.define(:name, :program, :frames, :probe, :color, :console_frames)

  # Steps, frame by frame, of the programs below: away to the bitmap screen on BITMAP_AWAY, back
  # on BITMAP_BACK, and looked at once after it is back (LOOK_BACK_FROM_BITMAP).
  BITMAP_AWAY = 5
  BITMAP_BACK = 9
  LOOK_BACK_FROM_BITMAP = 13

  SCENARIOS = [
    Scenario.new(name: :always_up_turn_kept_across_a_bitmap_screen, program: :always_up_turned_background,
                 frames: LOOK_BACK_FROM_BITMAP, probe: [200, 100], color: :red,
                 console_frames: LOOK_BACK_FROM_BITMAP + 1),
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
    shown = game_player.run(program, frames: scenario.frames).screen.shown
    x, y = scenario.probe
    assert_equal VBlank::Graphics::Color.resolve(scenario.color), shown[(y * SCREEN_W) + x],
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

  # A background every turning screen shows, red on its left half, turned half a circle about the
  # middle of the screen on frame 2. The turn is the game's, like a scroll, so it is still in
  # force after the bitmap screen: the red half is over to the right, low down.
  private def always_up_turned_background
    built do
      screen :rotozoom
      red_and_blue_art
      tiles :set, "#" => :red_art, "o" => :blue_art
      field = background :field, tiles: :set, map: Array.new(16) { ("#" * 8) + ("o" * 8) }
      across_a_bitmap_screen { |tick| (tick == 2).then { field.rotate 180 } }
    end
  end
end
