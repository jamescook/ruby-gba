# frozen_string_literal: true

require "test_helper"

# The iris: a circle that closes on a point until the screen is black, and opens again.
#
# It is the game's own light walked over frames, so what is asserted is the walk: shut at
# the end of the frames asked for, open again at the end of the way back, part way between
# on both backends alike — and a lantern the game had given back as it was.
class TestIris < Minitest::Test
  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A white room; +before+ runs before the loop, +each+ inside it.
  private def room(before: nil, each: nil)
    program do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      instance_exec(&before) if before
      game_loop { instance_exec(&each) if each }
    end
  end

  # --- a walk said in pixels a frame ---

  def test_a_walk_said_both_in_pixels_and_in_frames_is_refused
    error = assert_raises(ArgumentError) { room(before: -> { iris_out by: 4, frames: 10 }) }

    assert_match(/`by:`/, error.message)
    assert_match(/`frames:`/, error.message)
  end

  def test_an_iris_out_never_brought_back_is_a_warning
    out = StringIO.new
    err = StringIO.new
    RubyGBA.build("IRIS", console: :gba, out: out, err: err) do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      iris_out
      game_loop {}
    end

    assert_match(/never calls `iris_in`/, out.string + err.string)
  end

  def test_a_light_declared_after_an_iris_is_refused
    error = assert_raises(ArgumentError) do
      room(before: lambda {
        iris_out
        spotlight at: [10, 10], radius: 20
      })
    end

    assert_match(/before the first `iris_out`/, error.message)
  end
end
