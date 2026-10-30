# frozen_string_literal: true

require "test_helper"
require "differential"
require "all/vblank/builder/test_draw_column_at"

# The stretched column on the Advance's cartridge: the tear-free screen and the direct one held
# against each other, both read back in the emulator. What the column draws on every run is in
# test/all/vblank/builder/test_draw_column_at.rb.
class TestDrawColumnAtCartridge < Minitest::Test
  include Differential
  include DrawColumnAtTearFreeGames

  # THE POINT OF THE WHOLE BEAD: a game that moves to the tear-free screen to stop the
  # flicker must get the same picture it had before. Every one of the cases column_program
  # draws is compared across the two screens, so an odd column spliced into the wrong half — the
  # mistake this screen invites — shows up as a column of wrong pixels.
  def test_the_two_screens_draw_the_same_column
    tear_free = assert_emulator_loads_rom(assemble_rom(column_program(tear_free: true), name: "TFCOL"),
                                          frames: 6).frame_gba
    direct = assert_emulator_loads_rom(assemble_rom(column_program(tear_free: false), name: "DRCOL"),
                                       frames: 6).frame_gba

    differ = mismatched_pixels(direct, tear_free)

    assert_empty differ.first(8), "the two screens drew different pictures"
  end
end
