# frozen_string_literal: true

require "test_helper"
require "sound_comparison"

# The sound the desktop build makes for the console's two square-wave voices — a song's notes and
# a beep — against the sound the cartridge makes in the emulator, voice by voice and frame by
# frame (see SoundComparison for how it is judged and why it has the tolerances it has). Each
# test is a small program that does one thing; a whole game's sound is checked in a file of its
# own under examples/ beside this one.
class TestNativeTones < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include SoundComparison

  # A beep that fades: 440 Hz, a thin quarter wave, dropping a step of volume every 3/64 of a
  # second until it is gone. Beeps play on the second voice.
  def test_a_beep_has_the_consoles_pitch_tone_and_fade
    program = program_of do
      enable_sound
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 4).then { beep 440, duty: :quarter, decay: :medium, volume: 15 }
      end
    end

    assert_native_sounds_like_the_console program, frames: 70, voices: [:square2]
  end

  # A song in two parts, each on a voice of its own with its own tone and loudness, held notes
  # and rests, coming round twice.
  def test_a_songs_two_parts_sound_on_their_own_voices
    program = program_of do
      enable_sound
      song :tune do
        tempo 240
        voice :melody do
          duty :half
          note :A4, :quarter
          note :C5, :quarter
          rest :quarter
          note :E5, :quarter
        end
        voice :bass do
          duty :eighth
          volume 8
          note :A3, :half
          note :E3, :half
        end
      end
      play_song :tune
      game_loop {}
    end

    assert_native_sounds_like_the_console program, frames: 130
  end

  # The music turned down by hand and then faded out and back: a held note follows it.
  def test_the_music_volume_and_its_fades_are_heard
    program = program_of do
      enable_sound
      song :tune do
        tempo 60
        note :A4, :whole
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count.add! 1
        (count == 10).then { music_volume 50 }
        (count == 30).then { fade_music_out frames: 20 }
        (count == 70).then { fade_music_in frames: 20 }
      end
    end

    assert_native_sounds_like_the_console program, frames: 110, voices: [:square1]
  end

  # A beep borrows the second voice from a song's second part, and the music is then turned
  # down while the part's note is still being held: the voice sounds the PART'S note again at the
  # new volume, not the beep's.
  def test_a_volume_change_sounds_the_songs_note_again_and_not_a_beeps
    program = program_of do
      enable_sound
      song :tune do
        tempo 30
        voice(:melody) { note :A4, :whole }
        voice(:bass) { duty :quarter; note :E4, :whole }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count.add! 1
        (count == 20).then { beep 990, duty: :eighth, decay: :slow }
        (count == 30).then { music_volume 50 }
      end
    end

    assert_native_sounds_like_the_console program, frames: 90
  end
end
