# frozen_string_literal: true

require "test_helper"

# Pitched voices: `sample.play(pitch: :E4)` plays one recorded sample at a different note by
# reading through it faster (higher) or slower (lower) — so one recorded note covers a whole
# keyboard. The pitch shifts from the sample's own `note:` (default :C4). This is the piece
# the piano is built on. Here a higher note plays out sooner, on every lowering; the voice's play
# position and its fixed-point step, read off the Advance's cartridge, are in
# test/lowering/gba/vblank/dsl/test_pitched_voices_cartridge.rb.
class TestPitchedVoices < Minitest::Test
  def test_a_bad_pitch_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        s = sample :s, pcm: [0, 1], rate: 8000
        s.play(pitch: :H9) # not a note
      end
    end
    assert_match(/note/i, err.message)
  end

  # Play sample :s (recorded at :C4) once at the given pitch, then loop `frames` frames.
  private def play_for(frames, pitch)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      s = sample :s, pcm: [30] * 4000, rate: 8000, note: :C4 # ~0.5s at recorded pitch (~30 frames)
      pitch ? s.play(pitch: pitch) : s.play
      counter = var(:__f, 0)
      game_loop do
        wait_vblank
        counter.add! 1
        (counter >= frames).then { halt }
      end
    end
    game_player.run(b.program, frames: frames)
  end

  def test_a_higher_note_finishes_sooner
    base = play_for(20, nil)     # ~30 frames of sound -> still going at frame 20
    high = play_for(20, :C5)     # an octave up -> ~15 frames -> already done by 20
    assert_includes base.active_samples, :s, "the recorded pitch is still sounding at frame 20"
    refute_includes high.active_samples, :s, "an octave up has already finished by frame 20"
  end

  def test_a_lower_note_lasts_longer
    own = play_for(40, :C4)      # recorded pitch, ~30 frames -> already done by 40
    low = play_for(40, :C3)      # an octave down -> ~60 frames -> still going at 40
    refute_includes own.active_samples, :s, "the recorded pitch has finished by frame 40"
    assert_includes low.active_samples, :s, "an octave down is still sounding at frame 40"
  end
end
