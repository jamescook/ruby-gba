# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_instrument"

# THE TESTS OF test_instrument.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them; the rest are in test/all/vblank/dsl/test_instrument.rb.
#
# An instrument plays its one recording at the pitch of each note, and a Game Boy Color plays a
# recording only as it was recorded, one at a time, so a note, a chord or a note played from a
# button press is the Advance's alone.
class TestInstrumentOnTheAdvance < Minitest::Test
  include InstrumentGames

  def test_a_single_note_sounds
    i = play_frames(3) { |piano| piano.play(:E4) }
    assert_includes i.active_samples, :piano, "playing a note sounds the instrument"
  end

  def test_a_chord_sounds_several_notes_at_once
    i = play_frames(3) { |piano| piano.play(:C4, :E4, :G4) }
    assert_operator i.peak_voices, :>=, 3, "a three-note chord is three voices at once (#{i.peak_voices})"
  end

  def test_a_note_can_be_played_live_from_input
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      piano = instrument :piano, pcm: [40, -40] * 2000, rate: 8000, note: :C4 # ~0.5s, lasts a while
      counter = var(:__f, 0)
      game_loop do
        wait_vblank
        pressed(:a).then { piano.play(:C4) }
        counter.add! 1
        (counter >= 5).then { halt }
      end
    end
    # A pressed from frame 2 -> a note is triggered on the press edge, still sounding at frame 5
    i = game_player.input_each_frame { |f| f >= 2 ? [:a] : [] }.run(b.program, max_steps: 20_000)
    assert_includes i.active_samples, :piano, "pressing a button played a note"
  end
end
