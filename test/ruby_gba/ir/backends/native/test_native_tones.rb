# frozen_string_literal: true

require "test_helper"
require "sound_comparison"

# The sound the desktop build makes for the console's four voices — a song's notes and a beep on
# the two square-wave voices, a waveform on the wave voice, a hiss on the noise voice — against
# the sound the cartridge makes in the emulator, voice by voice and frame by frame (see
# SoundComparison for how it is judged and why it has the tolerances it has). Each test is a
# small program that does one thing; a whole game's sound is checked in a file of its own under
# examples/ beside this one.
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

  # A waveform of the game's own: high for a quarter of its length, which no named shape is.
  THIN_PULSE = ([15] * 8 + [0] * 24).freeze

  # The wave voice told what to play: a triangle at its loudest and then at half, a waveform
  # given as its steps at three quarters and a new pitch, and then told to stop.
  def test_the_wave_voice_plays_its_waveform_at_each_loudness
    program = program_of do
      enable_sound
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 4).then { wave :triangle, :A4 }
        (count == 20).then { wave :triangle, :A4, volume: :half }
        (count == 36).then { wave THIN_PULSE, :C4, volume: :three_quarter }
        (count == 52).then { stop_wave }
      end
    end

    assert_native_sounds_like_the_console program, frames: 70, voices: [:wave]
  end

  # Hits on the noise voice at each of its three pitches: a low rumble that fades slowly, a
  # rattle in the middle, and a thin high hiss, each cutting off the one before.
  def test_hits_on_the_noise_voice_hiss_and_fade
    program = program_of do
      enable_sound
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 4).then { noise :explosion }
        (count == 50).then { noise pitch: :mid, decay: :medium, volume: 13, metallic: true }
        (count == 90).then { noise :zap }
      end
    end

    assert_native_sounds_like_the_console program, frames: 140, voices: [:noise]
  end

  # The built-in hits, which are the sounds a game reaches for: a kick, a snare and a hat, each
  # with its own pitch, fade and rattle.
  def test_the_built_in_hits_sound_like_the_consoles
    program = program_of do
      enable_sound
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 4).then { noise :kick }
        (count == 50).then { noise :snare }
        (count == 80).then { noise :hat }
      end
    end

    assert_native_sounds_like_the_console program, frames: 110, voices: [:noise]
  end

  # The hiss is the console's own pattern, step for step: which way the voice stands on each of
  # its first steps, read off both as how long it stays there before it changes. A plain hiss and
  # a metallic one are different patterns — the metallic one out of fewer bits, so it comes round
  # sooner — and each is the console's. Played low, where a step is long enough to see, and with
  # no fade, so every step is as tall as the first.
  def test_the_hiss_is_the_consoles_pattern_plain_and_metallic
    [false, true].each do |rattles|
      program = program_of do
        enable_sound
        count = var :count, 0
        game_loop do
          count.add! 1
          (count == 4).then { noise pitch: :low, decay: :none, volume: 15, metallic: rattles }
        end
      end
      step = RubyGBA::Audio::Sound.noise_hit_step_ticks(:low).fdiv(RubyGBA::Audio::Sound::NOISE_CLOCK_HZ)
      wanted = console_voice(program, :noise, frames: 63).runs(step, 60)

      assert_equal 60, wanted.length, "the console's hiss should change sixty times in a second"
      assert_equal wanted, native_voice(program, :noise, frames: 60).runs(step, 60), (rattles ? "a metallic hiss" : "a plain hiss")
    end
  end

  # A song with a part on each of three voices: a lead on the square wave, a pad on the wave
  # voice with a rest in it, and drums on the noise voice — a low thump, a rest, and two higher
  # hisses that fade slowly — coming round twice.
  def test_a_songs_pad_and_drums_sound_on_the_wave_and_noise_voices
    program = program_of do
      enable_sound
      song :tune do
        tempo 120
        voice(:lead) { note :E5, :half; note :G5, :half }
        voice :pad, plays: :sine do
          volume 9
          note :C3, :quarter
          note :G3, :quarter
          rest :quarter
          note :C2, :quarter
        end
        voice :drums, plays: :noise do
          decay :slow
          note :C3, :quarter
          rest :quarter
          note 4000, :quarter
          note :C6, :quarter
        end
      end
      play_song :tune
      game_loop {}
    end

    assert_native_sounds_like_the_console program, frames: 250, voices: %i[square1 wave noise]
  end

  # The music turned down and faded out and in while the pad holds a note and the drums go on
  # hitting: the wave voice takes each new volume as it plays — the nearest of its five — and a
  # hit is struck at the volume in force when it falls.
  def test_the_music_volume_reaches_the_pad_and_the_drums
    program = program_of do
      enable_sound
      song :tune do
        tempo 60
        voice(:pad, plays: :triangle) { volume 15; note :C4, :whole }
        voice(:drums, plays: :noise) { volume 15; decay :none; note 6000, :quarter; note 6000, :quarter; note 6000, :half }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count.add! 1
        (count == 20).then { music_volume 50 }
        (count == 70).then { fade_music_out frames: 30 }
        (count == 130).then { fade_music_in frames: 30 }
      end
    end

    assert_native_sounds_like_the_console program, frames: 230, voices: %i[wave noise]
  end

  # `stop_wave` switches the voice off, and a song's pad then stays silent, note after note,
  # until something switches it on again: here the game's own `wave`, whose waveform the pad's
  # next notes are then played in. That is what the console does, so it is what is made here.
  def test_a_pad_stays_silent_after_stop_wave_until_the_voice_is_switched_on
    program = program_of do
      enable_sound
      song :tune do
        tempo 240
        voice(:pad, plays: :triangle) { note :C4, :quarter; note :E4, :quarter; note :G4, :quarter; note :C5, :quarter }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count.add! 1
        (count == 40).then { stop_wave }
        (count == 100).then { wave THIN_PULSE, :A3, volume: :half }
      end
    end

    assert_native_sounds_like_the_console program, frames: 180, voices: [:wave]
  end
end
