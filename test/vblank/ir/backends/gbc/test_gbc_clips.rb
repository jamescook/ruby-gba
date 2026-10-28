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

  def test_stopping_a_recording_quiets_the_wave_voice
    heard = console_voice(clip_game(waves: 400, stop_at: 10), :wave, frames: 25)

    assert_operator heard.loudness(7), :>=, SoundComparison::HEARD
    assert_operator heard.loudness(20), :<, SoundComparison::HEARD
  end
end
