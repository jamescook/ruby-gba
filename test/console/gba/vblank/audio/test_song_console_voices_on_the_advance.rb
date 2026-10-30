# frozen_string_literal: true

require "test_helper"

# THE TESTS OF vblank/audio/test_song_console_voices.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file. What the
# Advance's cartridge sounds, read in the emulator, is in
# test/lowering/gba/vblank/audio/test_song_console_voices_cartridge.rb.
#
# A SONG PART ON THE WAVE VOICE AND ON THE NOISE VOICE — the console's other two.
#
# A part played the square wave or a recorded instrument, and the console had two more voices a
# tune could use and did not: the wave voice, which loops a short waveform (rounder than a square
# wave, and it reaches an octave lower), and the noise voice, which makes a hiss (the drums).
#
# WHAT THEY ARE WORTH is that they cost NO mixer voice. A part that plays a recording keeps one
# of the mixer's voices for as long as its note sounds; these two the console makes itself. So a
# busy song reaches for them before it reaches for another recording, and the voices it does not
# spend stay free for the game's own sounds.
class TestSongConsoleVoicesOnTheAdvance < Minitest::Test
  # A tune whose parts cover every voice there is: two square, one wave, one noise, one recorded.
  private def every_voice_game(frames: 60)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song :full do
        tempo 150 # a quarter is 24 frames
        voice(:lead) { note :C5, :whole }
        voice(:bass) { note :C3, :whole }
        voice(:pad, plays: :triangle) { note :C2, :whole }
        voice(:drums, plays: :noise) { note :C2, :quarter; note :C5, :quarter }
        voice(:keys, plays: :piano) { note :E4, :whole }
      end
      play_song :full
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # --- the interpreter ---

  # The interpreter logs a song's wave and noise notes the way it logs the `wave` and `noise`
  # VERBS, because they really are the same voice — so one read of the log answers both.
  private def logged(program, frames: 6)
    game_player.run(program, frames: frames).audio
  end

  def test_a_wave_part_sounds_its_waveform_on_the_interpreter
    played = logged(every_voice_game).select { |entry| entry.first == :wave }.map(&:last)

    refute_empty played, "the pad part sounded the wave voice"
    assert_equal :triangle, played.first[:shape], "at the timbre the part named"
    assert_equal VBlank::Audio::Music::NOTE_FREQUENCIES[:C2], played.first[:frequency]
  end

  def test_a_noise_part_sounds_a_hit_on_the_interpreter
    hits = logged(every_voice_game).select { |entry| entry.first == :noise }.map(&:last).compact

    refute_empty hits, "the drum part hit the noise voice"
    assert_equal VBlank::Audio::Music::NOTE_FREQUENCIES[:C2], hits.first[:pitch]
    assert_equal :fast, hits.first[:decay], "a drum hit rings out rather than being held"
  end

  # THE POINT OF THE WHOLE THING. Five parts, and only the one playing a recording keeps a
  # mixer voice — so a tune with a pad and drums leaves fifteen of the sixteen for the game.
  def test_only_the_recorded_part_keeps_a_mixer_voice
    i = game_player.run(every_voice_game, frames: 6)

    assert_equal [:piano], i.active_samples
    assert_equal 1, i.peak_voices, "the wave and noise parts took none"
  end
end

