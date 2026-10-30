# frozen_string_literal: true

require "test_helper"
require "all/vblank/ir/test_frame_pairing"

# Which frame's numbers the picture was drawn from, on the Advance's cartridge: the variable
# and the picture read off the running cartridge at the same moment. Why the two line up the
# way they do, and the same asked of every run, is in test/all/vblank/ir/test_frame_pairing.rb.
class TestFramePairingCartridge < Minitest::Test
  include FramePairingGames

  def test_the_console_draws_a_programs_own_marker_from_this_frames_value
    value, drawn = console_pair(HAND_DRAWN)

    assert_equal value, drawn,
                 "the variable is #{value} and the picture was drawn from #{drawn.inspect}"
  end

  def test_the_console_draws_a_sprite_from_the_frame_befores_value
    value, drawn = console_pair(A_SPRITE)

    assert_equal value - 1, drawn,
                 "the variable is #{value} and the picture was drawn from #{drawn.inspect}"
  end

  # The same pair read off the console, the way a game's own test reads them: run the ROM
  # for a number of frames, then read a variable and a pixel.
  private def console_pair(source)
    rom = VBlank.build("PAIRING", console: :gba, validate: false, &source)
    verifier = assert_emulator_loads_rom(rom, frames: FRAMES, vars: rom.var_addresses)
    [verifier.var(:n), marker_column { |x, y| verifier.red?(x, y) }]
  end
end
