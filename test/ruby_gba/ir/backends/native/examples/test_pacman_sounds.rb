# frozen_string_literal: true

require "test_helper"
require "sound_comparison"
require_relative "../../../../../../examples/pacman"

# examples/pacman.rb built for the desktop sounds like the cartridge: the waka as Pac eats the
# pellet above him and the low buzz as the ghost catches him, both beeps on the second square
# voice, compared with the emulator frame by frame (see SoundComparison). The game has no song,
# so the first voice is not asked about.
class TestPacmanSounds < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include SoundComparison

  # Up through the pellet above him and on into the wall, then left alone until the ghost arrives.
  #
  # Held from the first frame and until well after he has reached the wall, because the console
  # starts its game a frame or two after the desktop build does: a button that goes down or comes
  # up while it still moves him would reach the two on different passes of the game, and the
  # ghost would then catch him on a different one.
  EAT_THEN_WAIT = Ractor.make_shareable(NativeComparison.held_for([1..50, :up]))

  def test_the_waka_and_the_catch
    program = Native.new.checked_program(Pacman::GAME, err: nil)
    native = native_voice(program, :square2, frames: 200, buttons: EAT_THEN_WAIT)
    heard = (0...native.frame_count).map { |frame| native.loudness(frame) >= HEARD }

    assert_operator heard.each_cons(2).count { |before, now| now && !before }, :>=, 2,
                    "both beeps should start in the run compared"
    assert_native_sounds_like_the_console program, frames: 200, buttons: EAT_THEN_WAIT, voices: [:square2]
  end
end
