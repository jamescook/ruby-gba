# frozen_string_literal: true

require "test_helper"
require "native_comparison"

# What the game as C says it played — the sound log a test reads with `audio` — matches what the
# interpreter says, entry for entry. Nothing comes out of a speaker in these runs; the log is
# what the player DID, which is what the tests of the music check.
class TestNativeSound < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  HeadlessRun = RubyGBA::IR::Backends::Native::HeadlessRun

  # +about+ is the kinds of entry the test is there for, which the interpreter's log has to hold
  # for the comparison to be worth anything.
  private def assert_same_sounds(program, frames:, about:)
    want = Reference.new.run(program, frames: frames).audio
    about.each { |kind| assert want.any? { |entry| entry.first == kind }, "the interpreter's log has no #{kind}: #{want.inspect}" }

    assert_equal want, HeadlessRun.new.run(program, frames: frames).audio
  end

  def test_switching_sound_on_and_a_beep
    program = program_of do
      enable_sound
      define_sound :ping, frequency: 880, duty: :quarter, decay: :fast
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 3).then { beep :ping }
        (count == 5).then { beep 440, volume: 9 }
      end
    end

    assert_same_sounds program, frames: 6, about: %i[enabled beep]
  end

  # Two parts in step, an introduction played once, and the rest coming round three times.
  def test_a_song_plays_its_parts_together_and_comes_round_from_its_loop_point
    program = program_of do
      enable_sound
      song :tune do
        tempo 600
        voice :melody do
          note :C4, :eighth
          loop_from_here
          note :E4, :eighth
          rest :eighth
          note :G4, :quarter
        end
        voice :bass do
          note :C3, :quarter
          note :G2, :quarter
          note :C3, :quarter
        end
      end
      play_song :tune
      game_loop {}
    end

    assert_same_sounds program, frames: 40, about: %i[note voice]
  end

  # Turned down by hand, then faded out and in: every held note follows, at the volume in force.
  def test_the_music_volume_and_its_fades_reach_the_notes_sounding
    program = program_of do
      enable_sound
      song :tune do
        tempo 300
        note :C4, :half
        note :E4, :quarter
        rest :quarter
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count.add! 1
        (count == 5).then { music_volume 50 }
        (count == 12).then { fade_music_out frames: 8 }
        (count == 30).then { fade_music_in frames: 6 }
      end
    end

    assert_same_sounds program, frames: 45, about: %i[note loudness]
  end

  # A stop, the same song named again in the same frame (which starts it over), and another
  # song taking over.
  def test_stopping_starting_over_and_switching_songs
    program = program_of do
      enable_sound
      song(:one) { tempo 300; note :C4, :quarter; note :D4, :quarter }
      song(:two) { tempo 300; note :A4, :eighth; note :B4, :eighth }
      count = var :count, 0
      game_loop do
        count.add! 1
        (count < 8).then { play_song :one }
        (count == 8).then { stop_music; play_song :one }
        (count > 12).then { play_song :two }
        (count == 20).then { stop_music }
      end
    end

    assert_same_sounds program, frames: 26, about: %i[note stop_music]
  end

  # A waveform of the game's own: 32 steps, where the named ones are a word.
  PULSE = ([15] * 8 + [0] * 24).freeze

  # The wave voice told to play and to stop, and hits on the noise voice, each said with
  # everything about it: a named waveform and one given as its steps, a loudness, a named hit
  # and one spelled out, and a hit with nothing said at all.
  def test_the_wave_and_noise_verbs
    program = program_of do
      enable_sound
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 2).then { wave :triangle, :C4 }
        (count == 3).then { wave PULSE, 440, volume: :half }
        (count == 4).then { stop_wave }
        (count == 5).then { noise :explosion }
        (count == 6).then { noise pitch: :high, decay: :slow, volume: 9, metallic: true }
        (count == 7).then { noise }
        (count == 8).then { wave :triangle, :C4 }
      end
    end

    assert_same_sounds program, frames: 9, about: %i[wave stop_wave noise]
  end

  # A song with a part on every one of the console's own voices: two on the square wave, a pad
  # on the wave voice and drums on the noise voice, with rests and notes at volumes of their own,
  # coming round twice.
  def test_a_song_plays_parts_on_the_wave_voice_and_the_noise_voice
    program = program_of do
      enable_sound
      song :tune do
        tempo 600
        voice(:lead) { note :C5, :quarter; note :E5, :quarter }
        voice(:bass) { duty :quarter; note :C3, :half }
        voice :pad, plays: :sine do
          volume 9
          note :C2, :quarter
          rest :eighth
          note :G2, :eighth
        end
        voice :drums, plays: :noise do
          decay :slow
          metallic true
          note :C2, :eighth
          note :C5, :eighth
          rest :eighth
          note :C6, :eighth
        end
      end
      play_song :tune
      game_loop {}
    end

    assert_same_sounds program, frames: 30, about: %i[wave stop_wave noise voice]
    assert_includes Reference.new.run(program, frames: 30).audio, [:noise, nil], "the drums rest"
  end

  # The music turned down and faded while the pad holds a note and the drums go on hitting: the
  # wave voice takes each new volume as it plays, and a hit is struck at the volume in force.
  def test_the_music_volume_reaches_the_wave_voice_and_the_next_hit
    program = program_of do
      enable_sound
      song :tune do
        tempo 300
        voice(:pad, plays: PULSE) { note :C3, :half; rest :quarter; note :E3, :quarter }
        voice(:drums, plays: :noise) { note :C4, :quarter; note :C4, :quarter; rest :quarter; note :C4, :quarter }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count.add! 1
        (count == 5).then { music_volume 50 }
        (count == 12).then { fade_music_out frames: 8 }
        (count == 30).then { fade_music_in frames: 6 }
      end
    end

    assert_same_sounds program, frames: 60, about: %i[wave noise loudness]
  end

  # The game's own `wave` and `noise` while a song is playing on the same two voices, and the
  # song stopped: the log holds each in the order it happened.
  def test_the_games_own_wave_and_noise_beside_a_songs
    program = program_of do
      enable_sound
      song :tune do
        tempo 300
        voice(:pad, plays: :triangle) { note :C3, :quarter; note :E3, :quarter }
        voice(:drums, plays: :noise) { note :C4, :quarter; note :C5, :quarter }
      end
      count = var :count, 0
      game_loop do
        count.add! 1
        (count < 20).then { play_song :tune }
        (count == 4).then { wave :sawtooth, :A4, volume: :quarter }
        (count == 6).then { noise :zap }
        (count == 9).then { stop_wave }
        (count == 20).then { stop_music }
      end
    end

    assert_same_sounds program, frames: 26, about: %i[wave stop_wave noise stop_music]
  end
end
