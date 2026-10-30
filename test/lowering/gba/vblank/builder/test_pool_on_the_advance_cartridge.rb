# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/builder/test_pool_on_the_advance"

# A pool too big for the quick memory, drawn by the Advance's cartridge in the emulator. What the
# game draws on every run that plays the Advance is in
# test/console/gba/vblank/builder/test_pool_on_the_advance.rb.
class TestPoolOnTheAdvanceCartridge < Minitest::Test
  include PoolOnTheAdvanceGames

  # The same from the roomier memory: a pool too big for the quick one is spawned into,
  # walked and read there like any other, the last of its thousand slots included.
  def test_a_pool_in_the_roomier_memory_draws_on_the_console
    # Filling and walking a thousand slots takes the console several frames.
    v = assert_emulator_loads_rom(assemble_rom(crowd_of_a_thousand, name: "CROWD"), frames: 40)
    assert v.green?(1, 21), "the first of the crowd drew, got 0x#{format('%04X', v.pixel_gba(1, 21))}"
    assert v.green?(200, 21), "and the last, got 0x#{format('%04X', v.pixel_gba(200, 21))}"
  end
end
