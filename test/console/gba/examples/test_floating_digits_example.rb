# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/floating_digits").to_s

# The floating-digits example: 0-9 drift around the screen and bounce off the
# walls, each in its own solid color, drawn as moving glyph images (blit) since a
# number whose position moves can't use the fixed-origin draw_text/draw_number.
# These assert BEHAVIOR — the digits render in their colors and actually move — on
# every run that plays the Advance's games; the emulator check that it renders on the
# console is in test/lowering/gba/examples/test_floating_digits_example_cartridge.rb.
class TestFloatingDigitsExample < Minitest::Test
  SW = VBlank::Console::ADVANCE.screen_width
  SH = VBlank::Console::ADVANCE.screen_height

  # Run the program on the interpreter for a fixed budget (deterministic — there's
  # no input), enough for every digit to have been drawn a few frames in.
  private def run_to(steps) = game_player.run(FloatingDigits.program, max_steps: steps)

  # Whether +color+ is painted anywhere on the screen.
  private def color_on?(screen, color)
    (0...SH).any? { |y| (0...SW).any? { |x| screen.pixel(x, y) == color } }
  end

  # Each digit renders as its own solid color. A couple may be hidden on any given
  # frame when two digits momentarily overlap, so we require most, not all, ten.
  def test_the_digits_render_in_their_own_colors
    screen = run_to(2000).screen
    present = FloatingDigits::COLORS.count { |rgb| color_on?(screen, Color.rgb(*rgb)) }
    assert_operator present, :>=, 8, "expected at least 8 of the 10 digit colors on screen, saw #{present}"
  end

  # They actually move: after a while, no digit sits at the pixel it started on.
  def test_the_digits_move_from_their_start
    i = run_to(2000)
    moved = (0...10).any? do |d|
      i[:"x#{d}"] != (10 + (d % 5) * 44) || i[:"y#{d}"] != (22 + (d / 5) * 74)
    end
    assert moved, "no digit moved from its start position"
  end

  # They stay on screen — the bounce keeps every digit fully within the field.
  def test_the_digits_stay_on_screen
    i = run_to(20_000)
    (0...10).each do |d|
      assert_includes 0..(SW - FloatingDigits::W), i[:"x#{d}"], "digit #{d} x drifted off screen"
      assert_includes 0..(SH - FloatingDigits::H), i[:"y#{d}"], "digit #{d} y drifted off screen"
    end
  end
end
