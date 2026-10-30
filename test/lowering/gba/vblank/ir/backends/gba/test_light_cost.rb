# frozen_string_literal: true

require "test_helper"

# WHAT A LIGHT COSTS THE CONSOLE ON A FRAME IT SHOWS NOTHING. A light is a window whose edges are
# worked out row by row in the gap between frames, and that is real work — so it is done only on
# a frame where the light shows something and has moved since it was last worked out. A light
# switched off in a scene that sees through a layer, one that darkens nothing, and one that stands
# still all cost next to nothing; one that moves costs its rows.
class TestLightCost < Minitest::Test
  # A white room, with +light+ run before the loop and +each+ inside it.
  private def room(light: nil, each: nil)
    VBlank.build("LIGHTCOST", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      instance_exec(&light) if light
      game_loop { instance_exec(&each) if each }
    end
  end

  # Instructions a frame rather than the share of each frame spare: every game here keeps up with
  # plenty to spare, so no pass spills into the next frame and the count reads the right way round,
  # and it says the light's rows in the same unit the console spends on them.
  private def per_frame(rom) = VBlank::Diagnostics::Profiler.run(rom, frames: 20, picture: false).samples_per_frame

  # Instructions a frame a room with +light+ and +each+ costs over the same room with neither.
  private def light_cost(light: nil, each: nil) = per_frame(room(light: light, each: each)) - per_frame(room)

  # Next to nothing: the light's darkness and its first row are said again, and nothing else.
  CHEAP = 400

  def setup
    require_emulator!
  end

  # A game with an iris it has not called yet has a light that reaches past the screen and
  # darkens nothing.
  def test_a_light_that_darkens_nothing_costs_next_to_nothing
    never = lambda {
      later = var :later, 0
      (later == 1).then { iris_out from: 150, by: 4 }
    }

    assert_operator light_cost(each: never), :<, CHEAP
  end

  def test_a_lantern_that_stands_still_costs_next_to_nothing
    assert_operator light_cost(light: -> { spotlight at: [120, 80], radius: 40, dark: 75 }), :<, CHEAP
  end

  # ...and one that moves is worked out again on every frame, which is what a light costs.
  def test_a_lantern_that_moves_works_its_rows_out
    moving = lambda {
      light = spotlight at: [120, 80], radius: 40, dark: 75
      step = var :step, 0
      once_a_frame do
        step.add! 1
        light.move_to 100 + (step & 31), 80
      end
    }

    assert_operator light_cost(light: moving), :>, CHEAP * 10
  end

  # A light shown now on every pass that has not changed works nothing out: its darkness and its
  # first row are said again, as in the gap.
  def test_showing_a_light_that_stands_still_costs_next_to_nothing
    shown = lambda {
      light = spotlight at: [120, 80], radius: 40, dark: 75
      once_a_frame { light.show_now }
    }

    assert_operator light_cost(light: shown), :<, CHEAP
  end

  # In a scene that sees through a layer the light is switched off, and costs nothing there.
  def test_a_light_switched_off_in_a_scene_costs_next_to_nothing
    with_title = lambda do |iris|
      VBlank.build("LIGHTOFF", console: :gba, out: StringIO.new, err: StringIO.new) do
        screen :tiled
        layers :ground, :water
        image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
        tiles :set, "#" => :white_tile
        layer(:ground) { background :room, tiles: :set, map: ["#" * 32] * 32 }
        var :mode, 0
        later = var :later, 0
        scene(:title) { layer(:water, transparency: 50) { background :pond, tiles: :set, map: ["#" * 32] * 32 } }
        scene(:playing) { (later == 1).then { iris_out from: 150, by: 4 } if iris }
        game_loop { case_var(:mode) { when_val 0, :title; when_val 1, :playing } }
      end
    end

    assert_operator per_frame(with_title.call(true)) - per_frame(with_title.call(false)), :<, CHEAP
  end
end
