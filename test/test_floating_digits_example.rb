# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "../examples/floating_digits"
require_relative "test_helper"

# The floating-digits example: 0-9 drift around the screen and bounce off the
# walls, each in its own solid color, drawn as moving glyph images (blit) since a
# number whose position moves can't use the fixed-origin draw_text/draw_number.
# These assert BEHAVIOR — the digits render in their colors and actually move — on
# the interpreter, with a gemba check that it renders on the console.
class TestFloatingDigitsExample < Minitest::Test
  include GembaSupport

  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  SW = FloatingDigits::SCREEN_W
  SH = FloatingDigits::SCREEN_H

  # Run the program on the interpreter for a fixed budget (deterministic — there's
  # no input), enough for every digit to have been drawn a few frames in.
  def run_to(steps) = Ruby.new.run(FloatingDigits.program, max_steps: steps)

  # Whether +color+ is painted anywhere on the screen.
  def color_on?(screen, color)
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

  # It renders on the console: digit 0 (the only red one) shows up along its early
  # top-left path.
  def test_it_renders_on_hardware
    rom = ROM.assemble(GBA.new.lower(FloatingDigits.program), title: "FLOATNUM", code: "BFLN", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)
    red = (4..30).any? { |y| (8..60).any? { |x| v.pixel_is?(x, y, Color.rgb(31, 0, 0)) } }
    assert red, "expected the red digit 0 somewhere along its early top-left path"
  end
end
