# frozen_string_literal: true

require "test_helper"
require "sound_comparison"
require_relative "../../../../../../examples/pong"

# examples/pong.rb built for the desktop sounds like the cartridge: its song on the first square
# voice, and its beeps — the ball off the walls and the paddles, a point scored — on the second,
# compared with the emulator voice by voice and frame by frame (see SoundComparison).
class TestPongSounds < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include SoundComparison

  # A held for a few frames, since the console is a frame or two behind the desktop build.
  START = Ractor.make_shareable((3..8).to_h { |frame| [frame, [:a]] })

  # START, the zoom, and a rally long enough for the song to come round and the ball to hit a
  # wall and a paddle.
  def test_a_rally_with_the_music_on
    program = Native.new.checked_program(PongGame::GAME, err: nil)

    assert_native_sounds_like_the_console program, frames: 420, buttons: START
  end

  # The music turned off on the title — down to its row, A, back up, A to start — leaves the first
  # voice silent on both and the beeps as they were.
  def test_a_rally_with_the_music_turned_off
    program = Native.new.checked_program(PongGame::GAME, err: nil)
    keys = [[3..6, :down], [14..19, :a], [28..31, :up], [40..45, :a]]
           .flat_map { |frames, button| frames.map { |frame| [frame, [button]] } }.to_h
    native = native_voice(program, :square1, frames: 420, buttons: keys)

    assert_nil native.first_heard, "the song should not play with the music off"
    assert_native_sounds_like_the_console program, frames: 420, buttons: keys, voices: [:square2]
  end
end
