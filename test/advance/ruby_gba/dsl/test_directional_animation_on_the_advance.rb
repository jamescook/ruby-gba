# frozen_string_literal: true

require "test_helper"

# The tests of test_directional_animation.rb whose games paint more colours into one 8×8 square
# of the screen than a Game Boy Color's square holds — a red, green, blue and white walker over
# a gray bitmap — so they play on the Advance's runs alone.
class TestDirectionalAnimationOnTheAdvance < Minitest::Test
  include RubyGBA::Console::Hardware

  # A hero at (40, 40) facing +face+, with a two-frame walk cycle per direction over a
  # gray field: right cycles red -> green, down cycles blue -> white. Each direction is
  # its own pair of colors, so the pixel at the hero says both which way it faces and
  # which frame is up. It halts after +run+ frames, so the screen is deterministic.
  private def walker(mode:, face:, run:, rate: 2)
    builder = Builder.new
    builder.instance_eval do
      screen mode
      if mode == :tiled
        image(:field, "#" => :gray) { SOLID_TILE }
        tiles :ground, "#" => :field
        background :bg, tiles: :ground, map: Array.new(20, "#" * 30)
      else
        clear_screen :gray
      end
      image(:rt0, "#" => :red)   { SOLID_TILE }
      image(:rt1, "#" => :green) { SOLID_TILE }
      image(:dn0, "#" => :blue)  { SOLID_TILE }
      image(:dn1, "#" => :white) { SOLID_TILE }
      hero = sprite :hero, at: [40, 40],
                          facing: { right: %i[rt0 rt1], down: %i[dn0 dn1] }, rate: rate
      hero.face face # face once, at setup — it holds while the frame animates
      f = var :f, 0
      game_loop do
        wait_vblank
        f.add! 1
        (f >= run).then { halt }
      end
    end
    builder.finalize_program
    builder.program
  end

  private def spot(program)
    game_player.run(program).screen.pixel(44, 44)
  end

  def test_facing_right_shows_the_right_walk_cycle
    assert_equal Color.resolve(:red),   spot(walker(mode: :bitmap, face: :right, run: 2)), "right, first frame"
    assert_equal Color.resolve(:green), spot(walker(mode: :bitmap, face: :right, run: 4)), "right, next frame"
  end

  def test_facing_down_shows_the_down_walk_cycle
    assert_equal Color.resolve(:blue),  spot(walker(mode: :bitmap, face: :down, run: 2)), "down, first frame"
    assert_equal Color.resolve(:white), spot(walker(mode: :bitmap, face: :down, run: 4)), "down, next frame"
  end

  # The whole point: turning does NOT reset to some other direction's frame. Facing down
  # shows a down color (blue/white), never a right color (red/green).
  def test_turning_switches_the_whole_cycle
    down = spot(walker(mode: :bitmap, face: :down, run: 2))
    refute_equal Color.resolve(:red),   down, "facing down must not show a right-facing frame"
    refute_equal Color.resolve(:green), down, "facing down must not show a right-facing frame"
  end
end
