# frozen_string_literal: true

require "test_helper"
require "stringio"
require "all/vblank/audio/test_song_parts"

# A song of many parts on the Advance's cartridge: the voices its mixer sounds, read in the
# emulator, and what mixing them costs. What the build says of such a song is in
# test/all/vblank/audio/test_song_parts.rb.
class TestSongPartsCartridge < Minitest::Test
  include SongPartsGames

  def test_the_console_sounds_all_twelve_recorded_parts_at_their_pitches_beside_the_games_sound
    console = assert_emulator_loads_rom(assemble_rom(fourteen_part_game, name: "SONG14"), frames: 6)
    organ = console.voices.select { |voice| voice.sample == :organ }.map(&:step).sort
    # A step is the note's pitch against the recorded one times the resampling — the mix runs
    # at a rate the sound hardware can sustain, not at the rate the organ was recorded at.
    resample = 8000.0 / console.sample_clock.rate
    expected = CHORD.map { |pitch| (NOTES[pitch].to_f / NOTES[:C4] * resample * STEP_ONE).round }

    assert_equal 12, organ.size, "twelve recorded parts sounding (#{console.voices.inspect})"
    organ.zip(expected).each { |got, want| assert_in_delta want, got, 2 }
    assert_equal [:hum], console.voices.map(&:sample) - [:organ], "...and the game's own sound with them"
    assert console.sound?
  end

  # --- a recorded part on its own, with NOTHING sounding beside it ---

  # THE TEST THAT WAS MISSING, and the reason a real bug lived here unnoticed: every hardware
  # test above has something ELSE making a noise at the same time — two square-wave parts and a
  # looping hum — so `sound?` was satisfied by the square wave while the recorded parts put out
  # nothing at all, and the twelve voices were read off the voice TABLE, which is bookkeeping
  # rather than audio. A tune whose melody is silent passes every one of them.
  #
  # So this is four parts on one instrument, no square part, no sound of the game's: if the
  # recordings are silent there is nothing left to hear.
  def test_a_song_of_recorded_parts_alone_is_audible_on_the_console
    console = assert_emulator_loads_rom(assemble_rom(recorded_parts_only_game, name: "PADS"), frames: 10)

    assert_equal [:organ] * 4, console.voices.map(&:sample), "four recorded parts hold four voices"
    assert console.sound?, "...and they are HEARD: nothing else in this program makes a sound, " \
                           "so silence here means the recordings never reached the speaker " \
                           "(energy #{console.audio_energy})"
  end

  # --- what it costs is measured, by name ---

  def test_the_profile_shows_what_the_music_costs
    tune = song_of(CHORD)
    rom = VBlank.build("SONGCOST", console: :gba, code: "ZSNC", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      enable_sound
      instance_exec(&tune)
      play_song :big
      game_loop { wait_vblank }
    end
    result = VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false)
    shares = result.lines.to_h { |line| [line.name, line.share] }

    assert_operator shares.fetch(:__mix_routine, 0), :>, 0, "mixing the eight parts is measured (#{shares.inspect})"
    assert_operator shares.fetch(:__interrupt, 0), :>, 0, "...and so is the player that starts their notes"
  end
end
