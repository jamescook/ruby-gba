# frozen_string_literal: true

require "test_helper"

# Pitched voices: `sample.play(pitch: :E4)` plays one recorded sample at a different note by
# reading through it faster (higher) or slower (lower) — so one recorded note covers a whole
# keyboard. The pitch shifts from the sample's own `note:` (default :C4). This is the piece
# the piano is built on.
#
# A Game Boy Color plays a recording only at the note it was recorded at, so the tests of a
# higher note playing out sooner are in
# test/console/gba/vblank/dsl/test_pitched_voices_on_the_advance.rb, and the voice's play
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
end
