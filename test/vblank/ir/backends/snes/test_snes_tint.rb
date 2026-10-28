# frozen_string_literal: true

require "test_helper"

# A fade or a tint on a Super Nintendo moves every colour of the colour memory (Runtime::Tint), and
# the picture is the interpreter's, pixel for pixel, after every pass (SNES::CheckedRun): on a
# tiled screen, backgrounds and sprites and the backdrop, and on a painted one. The amounts run
# past both ends and back, with whole percentages and fractions, so a step rounded the wrong way,
# a channel taken from the wrong bits or a fade left on when it should lift shows as a colour off.
class TestSNESTint < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  def test_a_tiled_screen_fades_to_black_and_white_and_tints_like_the_interpreter
    run = checked(frames: 60) do
      screen :tiled
      image :wall, "#" => rgb(31, 17, 3), "." => rgb(2, 29, 14) do
        "#.######\n" * 8
      end
      tiles :set, "#" => :wall
      background :room, tiles: :set, map: "####\n####\n"
      image(:ship, "." => :transparent, "o" => rgb(9, 9, 27)) { "oooo\no..o\noooo\n" }
      sprite :ship, at: [40, 3]
      t = var :t, -10
      game_loop do
        t.add! 7
        (t < 60).then { fade :black, t }
        (t >= 60).then { fade :white, t - 60 }
        (t >= 120).then { tint :red, t - 120 }
      end
    end

    assert_operator run[:t], :>, 120, "the tint was reached"
  end

  def test_a_painted_screen_fades_by_fractions_like_the_interpreter
    run = checked(frames: 40) do
      screen :bitmap
      clear_screen rgb(20, 11, 30)
      fill_rect 10, 10, 30, 20, :yellow
      level = var :level, 0.0
      game_loop do
        level.add! 3.3
        fade :white, level
      end
    end

    assert_operator run[:level], :>, 100, "past white and on"
  end

  private def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :snes }
  end

  private def checked(frames:, &game)
    SNES::CheckedRun.new.run(program_of(&game), frames: frames)
  end
end
