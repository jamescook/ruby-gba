# frozen_string_literal: true

require "test_helper"

require_relative "../examples/bird"

# The Bird example (examples/bird.rb): a sprite imported straight from a native .aseprite
# file — the whole animated bird, composited from its seven layers, with no export step.
# Proves it builds a clean ROM and the bird actually renders over the sky, on the
# interpreter oracle and on the console.
class TestBirdExample < Minitest::Test

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
    interp = Reference.new.run(Bird.program, frames: 3)
    assert bird_over_sky?(->(x, y) { interp.screen.pixel(x, y) }), "the bird should be drawn over the sky"
  end

  def test_the_bird_renders_on_the_console
    # The bird's tiles are stored packed in the ROM and expanded into video memory by
    # the BIOS at boot. That one-time expansion costs the first frame, so the sprite
    # first appears a frame later than an uncompressed one would — give it headroom.
    v = assert_gemba_loads_rom(Bird.build_rom(out: StringIO.new, err: StringIO.new), frames: 6)
    assert bird_over_sky?(->(x, y) { v.pixel_gba(x, y) }), "the bird should composite over the sky on hardware"
  end

  # The bird drifts nearer and further on its own, which is `pulse` running the sprite's
  # size. Read as a player would see it: the bird is drawn smaller at the bottom of the
  # drift than it is part-way up.
  def test_the_bird_drifts_nearer_and_further
    half = (Bird::DRIFT_SECONDS * 60 / 2).round
    smallest = drawn_size(1)
    biggest = drawn_size(half - 1)

    assert_in_delta Bird::FURTHEST, smallest, 0.02, "it starts at its furthest"
    assert_in_delta Bird::NEAREST, biggest, 0.02, "and reaches its nearest half a cycle later"
  end

  # The size the console is being told to draw the bird at, as the multiple the example
  # writes — read off the variable the pulse walks.
  def drawn_size(frames)
    interp = Reference.new.run(Bird.program, frames: frames, max_steps: 50_000_000)
    interp[:__obj1_scale] / RubyGBA::IR::Build::SCALE_ONE.to_f
  end
end
