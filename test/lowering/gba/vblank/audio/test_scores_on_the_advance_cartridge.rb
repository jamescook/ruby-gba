# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/audio/test_scores_on_the_advance"

# Songs with recorded instruments on the Advance's cartridge, heard in the emulator. What they
# play on every Advance run is in test/console/gba/vblank/audio/test_scores_on_the_advance.rb.
class TestScoresOnTheAdvanceCartridge < Minitest::Test
  include ScoresOnTheAdvanceGames

  # The music volume reaches it like any song while it plays: halved on pass 8, the held note
  # is set again at half. Moved after the song has ended, it sets nothing, since nothing is held.
  def test_the_music_volume_reaches_a_song_that_plays_once_until_it_ends
    energy = assert_emulator_loads_rom(assemble_rom(volume_moved_on_a_song_played_once, name: "SCOREVOL"),
                                       frames: 60).audio_energy_by_frame
    assert_operator energy[13..19].max, :<, energy[4..8].min, "quieter on the console too (#{energy.inspect})"
    assert_operator energy[45..].max, :<, energy[13..19].min / 4, "and silent after the end (#{energy.inspect})"
  end
end
