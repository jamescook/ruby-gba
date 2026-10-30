# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_frames_since_power_on"

# `frames_since_power_on` on the Advance's cartridge, read back in the emulator. What every run
# reads is in test/all/vblank/builder/test_frames_since_power_on.rb.
class TestFramesSincePowerOnCartridge < Minitest::Test
  include FramesSincePowerOnGames

  # THE ONE THAT MATTERS. On the console, setting up takes frames, and the reading counts them:
  # the first pass's change is first seen on frame F, so it ran after F - 1 frames had been
  # shown, and that is what it read. Spinning before the loop makes setting up take several.
  private def first_pass_on_the_console(busy)
    gba = GBA.new
    rom = ROM.assemble(gba.lower(counting_game(busy)), title: "POWERON")
    v = assert_emulator_loads_rom(rom, frames: 1, vars: gba.var_addresses)
    frame = 1
    until v.var(:passes).positive?
      flunk "no pass ran in 20 frames" if frame == 20
      v.step
      frame += 1
    end
    [frame, v.var(:first)]
  end

  def test_the_console_counts_the_frames_spent_setting_up
    quick_frame, quick = first_pass_on_the_console(0)
    slow_frame, slow = first_pass_on_the_console(30_000)

    assert_equal quick_frame - 1, quick, "a game that sets up at once reads the frames before its first pass"
    assert_operator slow_frame, :>, quick_frame, "spinning first should make setting up take longer"
    assert_equal slow_frame - 1, slow, "and the frames spent setting up are counted"
  end
end
