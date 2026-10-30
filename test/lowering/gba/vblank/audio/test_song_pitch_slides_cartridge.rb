# frozen_string_literal: true

require "test_helper"
require "all/vblank/audio/test_song_pitch_slides"

# A SLIDING NOTE ON THE ADVANCE'S CARTRIDGE: what the first square voice's register is told, read
# in the emulator. What a slide does in a song, on every run, is in
# test/all/vblank/audio/test_song_pitch_slides.rb.
class TestSongPitchSlidesCartridge < Minitest::Test
  include SongPitchSlidesGames

  # THE CONSOLE IS TOLD in the first square voice's sweep register: the 128ths of a second each
  # step waits in bits 4 to 6, 8 when it slides down, and the shift under that. A slow slide waits
  # seven, the most there is, which takes the register's top bit too.
  def test_the_console_is_told_how_each_note_slides
    program = song_game { voice(:lead) { |v| v.note :C5, :whole, slide_down: :slow } }
    console = assert_emulator_loads_rom(assemble_rom(program, name: "SLIDES"), frames: 4)

    assert_equal (7 << 4) | 8 | 5, console.mem16(VBlank::Console::Hardware::REG_SOUND1CNT_L) & 0x7F
  end
end
