# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"
require_relative "../examples/buffered_bounce"

# The buffered-bounce example (examples/buffered_bounce.rb): the worked demo that
# the tear-proof double-buffered screen is usable today with the fill/clear verbs.
# It clears and repaints the whole screen every frame — the pattern that tears a
# direct-color game — and stays clean because it's buffered. We prove it builds
# clean (which runs the guardrails and ROM-image checks) and actually renders its
# balls on a blue field, on both backends, so it can't rot into a black screen.
class TestBufferedBounceExample < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Ruby = RubyGBA::IR::Backends::Ruby
  Color = RubyGBA::Color

  BALL_COLORS = %i[yellow cyan magenta].freeze

  # RubyGBA.build runs the guardrails (raising on any fatal footgun) and the
  # ROM-image validation, so a clean build IS the check.
  def test_the_example_builds_clean
    rom = BufferedBounce.build_rom
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # On the reference interpreter, a settled frame shows the blue field and all
  # three balls — the promise that buffered drawing lands the same pixels.
  def test_it_renders_the_balls_on_a_blue_field
    i = Ruby.new.run(BufferedBounce.program)
    assert i.buffered, "the demo opts into double buffering"

    pixels = i.screen.to_a
    assert_includes pixels, Color.resolve(:blue), "the blue field should fill the screen"
    BALL_COLORS.each do |c|
      assert_includes pixels, Color.resolve(c), "the #{c} ball should be drawn"
    end
  end

  # On the console: gemba boots the ROM, resolves Mode 4 indices through the auto
  # palette, and presents the flipped page. The blue field and at least one ball
  # must render — not a black screen.
  def test_it_renders_on_the_console
    v = assert_gemba_loads_rom(BufferedBounce.build_rom, frames: 6)
    assert on_screen?(v, :blue), "the blue field should render on the console"
    assert BALL_COLORS.any? { |c| on_screen?(v, c) },
           "at least one ball should render on the console"
  end

  private

  # True if any pixel on a coarse grid is the given color. An 8x8 ball on even
  # columns always straddles the 4-pixel grid, so a drawn ball is never missed.
  def on_screen?(verifier, color)
    want = Color.resolve(color)
    (0...SCREEN_WIDTH).step(4).any? do |x|
      (0...SCREEN_HEIGHT).step(4).any? { |y| verifier.pixel_gba(x, y) == want }
    end
  end
end
