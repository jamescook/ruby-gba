# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/dsl/test_spotlight_show_now"

# A shaped light over a loop that waits for frames, on the Advance's cartridge: the console's own
# count of its turns and waits, read in the emulator. What `show_now` does on every run that
# plays the Advance's games is in test/console/gba/vblank/dsl/test_spotlight_show_now.rb.
class TestSpotlightShowNowCartridge < Minitest::Test
  include SpotlightShowNowGames

  # The gap between frames, where the light's own working out runs: a loop that waits for the next
  # frame inside itself makes all its passes on the console too.
  def test_a_loop_waiting_for_frames_keeps_its_count_under_a_shaped_light
    rom = assemble_rom(loop_waiting_under_a_shaped_light, name: "WAITLOOP")
    console = assert_emulator_loads_rom(rom, frames: 30, vars: rom.var_addresses)
    turns = console.var(:turns)

    assert_operator turns, :>=, 5, "the game made its turns"
    assert_includes ((turns - 1) * 3)..(turns * 3), console.var(:waited), "three waits a turn, as the loop says"
  end
end
