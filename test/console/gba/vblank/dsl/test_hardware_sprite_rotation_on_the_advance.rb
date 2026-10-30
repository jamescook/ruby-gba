# frozen_string_literal: true

require "test_helper"

# The tests of test_hardware_sprite_rotation.rb whose games turn a sprite to an angle, which a Game
# Boy Color's hardware cannot do, so they play on the Advance's runs alone.
class TestHardwareSpriteRotationOnTheAdvance < Minitest::Test
  # A 16x16 sprite whose LEFT half is red and RIGHT half is green — two big regions,
  # so a probe a few pixels off center reads one clear color and a pixel of sampling
  # slop can't flip the answer. Which half lands where after a turn reveals both that
  # it turned and which way.
  DISC_ART = (["RRRRRRRRGGGGGGGG"] * 16).join("\n")

  # The sprite over a blue floor, at a fixed build-time angle so its resting picture is
  # deterministic. face_angle with a whole number turns the sprite once, up front.
  private def turned_program(angle:, at: [40, 40])
    floor_map = Array.new(20, "#" * 30) # a blue floor filling the 240x160 screen
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :blue) { (["########"] * 8).join("\n") }
      image(:disc, "R" => :red, "G" => :green) { DISC_ART }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: floor_map
      disc = sprite :disc, at: at
      disc.face_angle(angle)
      f = var :f, 0
      game_loop do
        wait_vblank
        f.add! 1
        (f >= 2).then { halt }
      end
    end
    builder.finalize_program
    builder.program
  end

  # Center of the 16x16 sprite placed at (40, 40); probes sit 4 pixels off it, well
  # inside a half.
  CX = 48
  CY = 48

  # --- it turns, and the halves land where a clockwise turn puts them ---

  # Upright: left half red is to the LEFT of center, right half green to the RIGHT.
  def test_upright_the_left_half_is_on_the_left
    screen = game_player.run(turned_program(angle: 0)).screen
    assert_equal Color.resolve(:red),   screen.pixel(CX - 4, CY), "red left half is on the left"
    assert_equal Color.resolve(:green), screen.pixel(CX + 4, CY), "green right half is on the right"
  end

  # A quarter turn clockwise carries the left up and the right down: red now on top,
  # green on the bottom. (Top goes to the right, right to the bottom, and so on — so
  # the left rises to the top.)
  def test_a_quarter_turn_clockwise_moves_the_left_half_to_the_top
    screen = game_player.run(turned_program(angle: 90)).screen
    assert_equal Color.resolve(:red),   screen.pixel(CX, CY - 4), "the red half turned up to the top"
    assert_equal Color.resolve(:green), screen.pixel(CX, CY + 4), "the green half turned down to the bottom"
  end

  # --- turning accumulates and wraps ---

  # turn(100) each of five frames: 100, 200, 300, 400->40, 140. The angle stays in
  # 0..359 the whole way (the wrap after each turn), landing on 140.
  def test_turning_accumulates_and_wraps_into_range
    prog = begin
      builder = Builder.new
      builder.instance_eval do
        screen :tiled
        image(:floor, "#" => :blue) { (["########"] * 8).join("\n") }
        image(:disc, "R" => :red, "G" => :green) { DISC_ART }
        tiles :ground, "#" => :floor
        background :field, tiles: :ground, map: Array.new(20, "#" * 30)
        disc = sprite :disc, at: [40, 40]
        f = var :f, 0
        game_loop do
          wait_vblank
          disc.turn(100)
          f.add! 1
          (f >= 5).then { halt }
        end
      end
      builder.finalize_program
      builder.program
    end
    i = game_player.run(prog)
    assert_equal 140, i[:__obj1_angle], "the angle accumulated and wrapped to 140"
  end
end
