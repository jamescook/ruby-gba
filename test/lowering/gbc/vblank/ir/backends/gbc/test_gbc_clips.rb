# frozen_string_literal: true

require "test_helper"
require "sound_comparison"

# THE COLOR CARTRIDGE'S OWN SOUND FOR A RECORDING: a sample at a time, a bit each, on the wave voice
# (Runtime::Clips). The run's log says the game started and stopped it; this hears that the voice
# was told. A recording of a square wave, sixteen samples up and sixteen down at 8192 a second, is a
# note of 256Hz however the clip is played, and the voice falls quiet when the clip is over or the
# game stops it.
class TestGBCClips < Minitest::Test
  include SoundComparison

  # A square wave of 256Hz, recorded at 8192 samples a second: +waves+ of them.
  private def square_recording(waves) = ([80] * 16 + [-80] * 16) * waves

  # The pitch most of +frames+ hold, as one note: a frame here and there is read as no one note
  # even with nothing but a held note sounding, so a pitch is asked of a stretch, not a frame.
  private def pitch_held_through(heard, frames)
    pitches = frames.filter_map { |frame| heard.held_note(frame)&.pitch }
    assert_operator pitches.size, :>=, (frames.size + 1) / 2, "one note held through frames #{frames}"
    pitches.sort[pitches.size / 2]
  end

  # A Color game playing the recording on its third pass, at +volume+, and stopping it on pass
  # +stop_at+ (never, for nil).
  private def clip_game(waves:, stop_at: nil, volume: :full)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    recording = square_recording(waves)
    b.instance_eval do
      screen :tiled
      hum = sample :hum, pcm: recording
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 3).then { hum.play(volume: volume) }
        (count == stop_at).then { hum.stop } if stop_at
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_recording_sounds_on_the_wave_voice_at_its_own_pitch
    heard = console_voice(clip_game(waves: 200), :wave, frames: 30)

    assert_in_delta 256, heard.held_note(15).pitch, 4
  end

  # 100 waves are 3200 samples, a little under 24 frames: the voice is quiet by frame 40.
  def test_the_wave_voice_is_quiet_once_the_recording_is_over
    heard = console_voice(clip_game(waves: 100), :wave, frames: 45)

    assert_operator heard.loudness(12), :>=, SoundComparison::HEARD
    assert_operator heard.loudness(40), :<, SoundComparison::HEARD
  end

  # The wave voice's own half: a 1 pushes the speaker half as far.
  def test_a_recording_played_at_half_is_half_as_tall
    full = console_voice(clip_game(waves: 200), :wave, frames: 20)
    half = console_voice(clip_game(waves: 200, volume: :half), :wave, frames: 20)

    assert_in_delta 0.5, half.height(15) / full.height(15), 0.1
  end

  # A SONG WITH A PART ON THE WAVE VOICE, AND A RECORDING OVER IT: the recording has the voice while
  # it plays, and the part has it back for its next note. A440 a quarter note at a time, so a note
  # starts every half second, inside the recording and after it.
  private def clip_over_a_wave_part
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    recording = square_recording(200)
    b.instance_eval do
      screen :tiled
      enable_sound
      song :pad do
        tempo 120
        voice(:low, plays: :wave) { |v| 8.times { v.note :A4, :quarter } }
      end
      play_song :pad
      hum = sample :hum, pcm: recording
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 3).then { hum.play }
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_recording_over_a_wave_part_keeps_its_own_pitch
    heard = console_voice(clip_over_a_wave_part, :wave, frames: 80)

    assert_in_delta 256, heard.held_note(40).pitch, 4, "the recording, through the part's next note"
    assert_in_delta 440, heard.held_note(70).pitch, 6, "the part's own note once the recording is over"
  end

  # A WAVE NOTE HELD ACROSS A RECORDING: one A440 held four seconds, and a recording of a little under
  # 24 frames over its start, ended by itself or stopped by the game on pass +stop_at+. The note has
  # the voice back as soon as the recording is over, not at the part's next note, which never comes.
  private def clip_over_a_held_wave_note(stop_at: nil)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    recording = square_recording(100)
    b.instance_eval do
      screen :tiled
      enable_sound
      song :drone do
        tempo 60
        voice(:low, plays: :wave) { |v| v.note :A4, :whole }
      end
      play_song :drone
      hum = sample :hum, pcm: recording
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 3).then { hum.play }
        (count == stop_at).then { hum.stop } if stop_at
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_wave_note_held_across_a_recording_sounds_again_at_its_end
    heard = console_voice(clip_over_a_held_wave_note, :wave, frames: 50)

    assert_in_delta 256, pitch_held_through(heard, 10..16), 4, "the recording"
    assert_operator heard.loudness(40), :>=, SoundComparison::HEARD, "the held note, back once the recording is over"
    assert_in_delta 440, pitch_held_through(heard, 36..44), 6
  end

  def test_a_wave_note_held_across_a_recording_the_game_stops_sounds_again
    heard = console_voice(clip_over_a_held_wave_note(stop_at: 10), :wave, frames: 30)

    assert_operator heard.loudness(20), :>=, SoundComparison::HEARD, "the held note, back once the game stops the recording"
    assert_in_delta 440, pitch_held_through(heard, 18..26), 6
  end

  # THE GAME'S OWN WAVE beside a recording of a little under 24 frames played on pass +play_at+: said
  # on pass +wave_at+, a 440 triangle; the recording has the voice while it plays, and the wave has it
  # after.
  private def game_wave_beside_a_recording(wave_at:, play_at: 3)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    recording = square_recording(100)
    b.instance_eval do
      screen :tiled
      enable_sound
      hum = sample :hum, pcm: recording
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == wave_at).then { wave :triangle, 440 }
        (count == play_at).then { hum.play }
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_wave_said_while_a_recording_plays_sounds_as_it_ends
    heard = console_voice(game_wave_beside_a_recording(wave_at: 8), :wave, frames: 45)

    assert_in_delta 256, pitch_held_through(heard, 12..18), 4, "the recording, not the wave said over it"
    assert_in_delta 440, pitch_held_through(heard, 36..44), 6, "the wave, once the recording is over"
  end

  def test_a_wave_sounding_as_a_recording_starts_comes_back_as_it_ends
    heard = console_voice(game_wave_beside_a_recording(wave_at: 1, play_at: 12), :wave, frames: 55)

    assert_in_delta 440, pitch_held_through(heard, 8..14), 6, "the wave, before the recording"
    assert_in_delta 256, pitch_held_through(heard, 20..34), 4, "the recording"
    assert_in_delta 440, pitch_held_through(heard, 42..52), 6, "the wave again"
  end

  # A SOUND EFFECT WITH A WAVE PART, started with a recording: A4 at once and A5 thirty frames on (at
  # 150 beats a minute a tick is a frame). The recording has the voice while it plays; the effect's
  # note after it is heard.
  private def effect_beside_a_recording
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    recording = square_recording(100)
    score = VBlank::Audio::Score
    notes = [score::Note.new(at: 0, key: :A4), score::Note.new(at: 30, key: :A5)]
    effect = score.new(tempo: 150, length: 60, parts: [score::Part.new(plays: :wave, notes: notes)])
    b.instance_eval do
      screen :tiled
      enable_sound
      sfx = sound_effects :sfx, { chime: effect }
      hum = sample :hum, pcm: recording
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 3).then do
          hum.play
          sfx.play :chime
        end
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_sound_effects_wave_note_after_a_recording_is_heard
    heard = console_voice(effect_beside_a_recording, :wave, frames: 50)

    assert_in_delta 256, pitch_held_through(heard, 12..18), 4, "the recording, not the effect's first note"
    assert_in_delta 880, pitch_held_through(heard, 38..46), 10, "the effect's next note, once the recording is over"
  end

  def test_stopping_a_recording_quiets_the_wave_voice
    heard = console_voice(clip_game(waves: 400, stop_at: 10), :wave, frames: 25)

    assert_operator heard.loudness(7), :>=, SoundComparison::HEARD
    assert_operator heard.loudness(20), :<, SoundComparison::HEARD
  end
end
