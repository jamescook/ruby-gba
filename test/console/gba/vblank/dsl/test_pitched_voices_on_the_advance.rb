# frozen_string_literal: true

require "test_helper"

# The tests of test/all/vblank/dsl/test_pitched_voices.rb that play a recording at another note. A
# Game Boy Color plays a recording only as it was recorded, so these play on the Advance's runs
# alone. The voices read off the Advance's cartridge are in
# test/lowering/gba/vblank/dsl/test_pitched_voices_cartridge.rb.
#
# Pitched voices: `sample.play(pitch: :E4)` plays one recorded sample at a different note by
# reading through it faster (higher) or slower (lower). Here a higher note plays out sooner.
class TestPitchedVoicesOnTheAdvance < Minitest::Test
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

  # --- the surface (interpreter): a higher note plays out faster ---

  def test_a_higher_note_finishes_sooner
    base = play_for(20, nil)     # ~30 frames of sound -> still going at frame 20
    high = play_for(20, :C5)     # an octave up -> ~15 frames -> already done by 20
    assert_includes base.active_samples, :s, "the recorded pitch is still sounding at frame 20"
    refute_includes high.active_samples, :s, "an octave up has already finished by frame 20"
  end

  def test_a_lower_note_lasts_longer
    high = play_for(20, :C4)     # recorded pitch, ~30 frames
    low  = play_for(20, :C3)     # an octave down -> ~60 frames
    # both still sounding at 20, but the low one has plenty left — sanity that low != high
    assert_includes low.active_samples, :s, "an octave down is still sounding at frame 20"
    refute_nil high.volume_of(:s)
  end
end
