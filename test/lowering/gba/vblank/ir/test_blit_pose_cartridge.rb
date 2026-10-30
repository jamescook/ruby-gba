# frozen_string_literal: true

require "test_helper"
require "all/vblank/ir/test_blit_pose"

# blit_pose on the Advance's cartridge, read back in the emulator. What the index selects on
# every run is in test/all/vblank/ir/test_blit_pose.rb.
class TestBlitPoseCartridge < Minitest::Test
  include BlitPosePrograms

  # ---- hardware: the selected pose renders on the console ----

  def test_the_selected_pose_renders_on_the_console
    rom0 = ROM.assemble(GBA.new.lower(pose_program(0)), title: "POSE0", code: "BPS0", maker: "01")
    v0 = assert_emulator_loads_rom(rom0, frames: 2)
    assert v0.red?(10, 10), "pose 0 (red) didn't render on hardware — got #{v0.pixel_gba(10, 10).to_s(16)}"

    rom1 = ROM.assemble(GBA.new.lower(pose_program(1)), title: "POSE1", code: "BPS1", maker: "01")
    v1 = assert_emulator_loads_rom(rom1, frames: 2)
    assert v1.green?(10, 10), "pose 1 (green) didn't render on hardware — got #{v1.pixel_gba(10, 10).to_s(16)}"
  end
end
