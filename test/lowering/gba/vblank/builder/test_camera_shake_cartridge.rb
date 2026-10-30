# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_camera_shake"

# The screen shake on the Advance's cartridge, read back in the emulator. What the camera and
# the shake do on every run is in test/all/vblank/builder/test_camera_shake.rb.
class TestCameraShakeCartridge < Minitest::Test
  include CameraShakeGames

  # The shake really moves the picture on the hardware, and really puts it back.
  # Two ROMs of the same game stopped at different frames: one mid-shake, one after.
  def test_the_shake_moves_the_picture_on_the_console_and_restores_it
    mid = ROM.assemble(GBA.new.lower(shaking_game(frames: 4, intensity: 6, length: 6)),
                       title: "SHAKE", code: "BSHK", maker: "01")
    done = ROM.assemble(GBA.new.lower(shaking_game(frames: 20, intensity: 6, length: 3)),
                        title: "SHAKE", code: "BSHK", maker: "01")

    during = assert_emulator_loads_rom(mid, frames: 6)
    after = assert_emulator_loads_rom(done, frames: 24)

    # The block was drawn across x 100..139. After the shake it is exactly there.
    assert after.red?(120, 80), "the block should be back where it was drawn, " \
                                "got 0x#{format('%04X', after.pixel_gba(120, 80))}"

    # Two points just outside the block, one past each edge. Settled, both show
    # background. Under a 6px shake the picture has slid one way or the other, so one
    # of them is covered by the block — whichever way this frame happens to lean.
    assert during.red?(97, 80) || during.red?(142, 80),
           "mid-shake the picture should have slid over one of the two edge points"
    refute after.red?(97, 80), "settled, the block covers neither"
    refute after.red?(142, 80)
  end
end
