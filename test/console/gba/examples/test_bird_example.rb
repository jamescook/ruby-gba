# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/bird").to_s

# How to tell the bird is on screen, kept once for this file and for the test of the bird on
# the Advance's cartridge (test/lowering/gba/examples/test_bird_example_cartridge.rb).
module BirdExamplePictures
  SKY = VBlank::Graphics::Color.rgb(12, 18, 28) # the background tile color

  # The bird sits at (88, 48) sized 64x64. Somewhere in that box a non-sky pixel is the
  # bird drawn over the sky. +sample+ reads a pixel; nil / 0 / the sky color are "not bird".
  private def bird_over_sky?(sample)
    (90..148).step(4).any? do |x|
      (50..108).step(4).any? do |y|
        px = sample.call(x, y)
        px && px != SKY && px != 0
      end
    end
  end
end

# The Bird example (examples/bird.rb): a sprite imported straight from a native .aseprite
# file — the whole animated bird, composited from its seven layers, with no export step.
# Proves it builds a clean ROM and the bird actually renders over the sky. The bird on the
# Advance's cartridge is in test/lowering/gba/examples/test_bird_example_cartridge.rb.
class TestBirdExample < Minitest::Test
  include BirdExamplePictures

  def test_it_builds_a_rom
    assert_operator Bird.build_rom(out: StringIO.new, err: StringIO.new).size, :>, 0
  end

  def test_the_bird_renders_on_the_interpreter
    interp = game_player.run(Bird.program, frames: 3)
    assert bird_over_sky?(->(x, y) { interp.screen.pixel(x, y) }), "the bird should be drawn over the sky"
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
  private def drawn_size(frames)
    interp = game_player.run(Bird.program, frames: frames, max_steps: 50_000_000)
    interp[:__obj1_scale] / VBlank::IR::Build::SCALE_ONE.to_f
  end
end
