# frozen_string_literal: true

require "test_helper"
require "all/vblank/audio/test_song_note_fades"

# A song's fading and swelling notes as the Advance's cartridge tells its sound hardware of them.
# What the notes do on every run is in test/all/vblank/audio/test_song_note_fades.rb.
class TestSongNoteFadesCartridge < Minitest::Test
  include SongNoteFadesGames

  # THE CONSOLE IS TOLD, in each voice's control register: its tone in bits 6 and 7, the step in
  # bits 8 to 10, 8 more when it swells, and the volume it starts at on top. The register's low six
  # bits are a note length the voice never shows back, so they are left out of what is read.
  def test_the_console_is_told_how_each_note_fades
    console = assert_emulator_loads_rom(assemble_rom(fade_and_swell_game, name: "FADES"), frames: 4)
    half = 2 << 6

    assert_equal 0xC000 | 0x0500 | half, console.mem16(VBlank::Console::Hardware::REG_SOUND1CNT_H) & 0xFFC0,
                 "the lead starts at 12 and steps down every five 64ths of a second"
    assert_equal 0x0800 | 0x0100 | half, console.mem16(VBlank::Console::Hardware::REG_SOUND2CNT_L) & 0xFFC0,
                 "the pad starts at nothing and steps up every 64th"
  end
end
