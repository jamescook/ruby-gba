# frozen_string_literal: true

require "test_helper"

# The program these tests play, kept once for the pose read back on the Advance's cartridge too
# (test/lowering/gba/vblank/ir/test_blit_pose_cartridge.rb).
module BlitPosePrograms
  include SharedConstants
  include VBlank::IR::Build

  # Two 2x2 poses: one solid red, one solid green. Index picks which one draws.
  private def pose_program(index)
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
end

# blit_pose: draw one of a set of same-size images, chosen by a run-time index —
# the primitive under a sprite that faces the way it moves (and, later, animation
# frames). The proof is "the index selects the pose": a different index paints a
# different image at the same spot.
class TestBlitPose < Minitest::Test
  include BlitPosePrograms

  def test_index_zero_draws_the_first_pose
    s = game_player.run(pose_program(0)).screen
    assert_equal Color.resolve(:red), s.pixel(10, 10), "index 0 should draw the red pose"
    assert_equal Color.resolve(:red), s.pixel(11, 11)
  end

  def test_index_one_draws_the_second_pose
    s = game_player.run(pose_program(1)).screen
    assert_equal Color.resolve(:green), s.pixel(10, 10), "index 1 should draw the green pose"
    refute_equal Color.resolve(:red), s.pixel(11, 11), "the red pose should not be drawn"
  end

  def test_an_out_of_range_index_draws_nothing
    s = game_player.run(pose_program(5)).screen
    assert_equal Color.resolve(:black), s.pixel(10, 10), "an out-of-range pose index draws nothing"
  end

  # The selected pose on the Advance's cartridge, read back in the emulator, is in
  # test/lowering/gba/vblank/ir/test_blit_pose_cartridge.rb.
end
