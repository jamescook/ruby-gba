# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# blit_pose: draw one of a set of same-size images, chosen by a run-time index —
# the primitive under a sprite that faces the way it moves (and, later, animation
# frames). The proof is "the index selects the pose": a different index paints a
# different image at the same spot. Asserted on the interpreter and on gemba, and
# the two backends must agree.
class TestBlitPose < Minitest::Test
  include GembaSupport
  include RubyGBA::IR::Build

  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  # Two 2x2 poses: one solid red, one solid green. Index picks which one draws.
  def pose_program(index)
    program(
      screen(:bitmap),
      clear_screen(:black),
      bitmap(:red2, width: 2, height: 2, pixels: ([Color.resolve(:red)] * 4).pack("v*"), transparent: nil),
      bitmap(:grn2, width: 2, height: 2, pixels: ([Color.resolve(:green)] * 4).pack("v*"), transparent: nil),
      set(:pose, int(index)),
      blit_pose([:red2, :grn2], var_ref(:pose), int(10), int(10)),
      halt
    )
  end

  def test_index_zero_draws_the_first_pose
    s = Ruby.new.run(pose_program(0)).screen
    assert_equal Color.resolve(:red), s.pixel(10, 10), "index 0 should draw the red pose"
    assert_equal Color.resolve(:red), s.pixel(11, 11)
  end

  def test_index_one_draws_the_second_pose
    s = Ruby.new.run(pose_program(1)).screen
    assert_equal Color.resolve(:green), s.pixel(10, 10), "index 1 should draw the green pose"
    refute_equal Color.resolve(:red), s.pixel(11, 11), "the red pose should not be drawn"
  end

  def test_an_out_of_range_index_draws_nothing
    s = Ruby.new.run(pose_program(5)).screen
    assert_equal Color.resolve(:black), s.pixel(10, 10), "an out-of-range pose index draws nothing"
  end

  # ---- hardware: the selected pose renders on the console ----

  def test_the_selected_pose_renders_on_gemba
    rom0 = ROM.assemble(GBA.new.lower(pose_program(0)), title: "POSE0", code: "BPS0", maker: "01")
    v0 = assert_gemba_loads_rom(rom0, frames: 2)
    assert v0.red?(10, 10), "pose 0 (red) didn't render on hardware — got #{v0.pixel_gba(10, 10).to_s(16)}"

    rom1 = ROM.assemble(GBA.new.lower(pose_program(1)), title: "POSE1", code: "BPS1", maker: "01")
    v1 = assert_gemba_loads_rom(rom1, frames: 2)
    assert v1.green?(10, 10), "pose 1 (green) didn't render on hardware — got #{v1.pixel_gba(10, 10).to_s(16)}"
  end
end
