# frozen_string_literal: true

require "test_helper"

# The piano these tests play, shared with the Advance's own tests of the same instrument
# (test/console/gba/vblank/dsl/test_instrument_on_the_advance.rb).
module InstrumentGames
  include SharedConstants

  # Build a piano, hand it to the block to play, then loop `frames` frames.
  private def play_frames(frames, &use)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      piano = instrument :piano, pcm: [40, -40] * 2000, rate: 8000, note: :C4
      instance_exec(piano, &use)
      counter = var(:__f, 0)
      game_loop do
        wait_vblank
        counter.add! 1
        (counter >= frames).then { halt }
      end
    end
    game_player.run(b.program, max_steps: 200_000)
  end
end

# A playable sampled instrument: `instrument :piano, from: …` turns one recording into a
# whole keyboard you play *notes* on — `piano.play(:E4)`, or `piano.play(:C4, :E4, :G4)` for
# a chord that sounds all at once. It's a thin, note-named layer over pitched mixer voices
# (no rates/voices/mixer detail exposed).
#
# A note, a chord and a note played from a button press are in
# test/console/gba/vblank/dsl/test_instrument_on_the_advance.rb: the Game Boy Color plays a
# recording only at the note it was recorded at. A chord as three distinct pitched voices on the
# Advance's cartridge is in test/lowering/gba/vblank/dsl/test_instrument_cartridge.rb.
class TestInstrument < Minitest::Test
  include InstrumentGames

  def test_playing_no_note_is_a_friendly_error
    err = assert_raises(ArgumentError) { play_frames(1) { |piano| piano.play } }
    assert_match(/note/i, err.message)
  end

  def test_an_unknown_note_is_a_friendly_error
    err = assert_raises(ArgumentError) { play_frames(1) { |piano| piano.play(:Z9) } }
    assert_match(/note/i, err.message)
  end
end
