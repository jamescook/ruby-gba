# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"
require_relative "../examples/bird"

# The Bird example (examples/bird.rb): a sprite imported straight from a native .aseprite
# file — the whole animated bird, composited from its seven layers, with no export step.
# Proves it builds a clean ROM and the bird actually renders over the sky, on the
# interpreter oracle and on the console.
class TestBirdExample < Minitest::Test
  include GembaSupport

  Ruby = RubyGBA::IR::Backends::Ruby
  SKY = RubyGBA::Color.rgb(12, 18, 28) # the background tile color

  def test_it_builds_a_rom
    assert_operator Bird.build_rom(out: StringIO.new, err: StringIO.new).size, :>, 0
  end

  # The bird sits at (88, 48) sized 64x64. Somewhere in that box a non-sky pixel is the
  # bird drawn over the sky. +sample+ reads a pixel; nil / 0 / the sky color are "not bird".
  def bird_over_sky?(sample)
    (90..148).step(4).any? do |x|
      (50..108).step(4).any? do |y|
        px = sample.call(x, y)
        px && px != SKY && px != 0
      end
    end
  end

  def test_the_bird_renders_on_the_interpreter
    interp = Ruby.new.run(Bird.program, frames: 3)
    assert bird_over_sky?(->(x, y) { interp.screen.pixel(x, y) }), "the bird should be drawn over the sky"
  end

  def test_the_bird_renders_on_the_console
    v = assert_gemba_loads_rom(Bird.build_rom(out: StringIO.new, err: StringIO.new), frames: 3)
    assert bird_over_sky?(->(x, y) { v.pixel_gba(x, y) }), "the bird should composite over the sky on hardware"
  end
end
