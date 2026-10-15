# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require "sound_comparison"
require RubyGBA.root.join("examples/pacman").to_s

# examples/pacman.rb built for the desktop sounds like the cartridge: the waka as Pac eats the
# pellet above him and the low buzz as the ghost catches him, both beeps on the second square
# voice, compared with the emulator frame by frame (see SoundComparison). The game has no song,
# so the first voice is not asked about.
class TestPacmanSounds < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include SoundComparison

  # Up through the pellet above him and on into the wall, then left alone until the ghost arrives.
  # Held from the first frame until well after he has reached the wall, so the two play the same
  # game though the console starts a frame or two later (see .claude/rules/testing.md).
  EAT_THEN_WAIT = Ractor.make_shareable(NativeComparison.held_for([1..50, :up]))

  def test_the_waka_and_the_catch
    program = Native.new.checked_program(Pacman::GAME, err: nil)
    played = Native::HeadlessRun.new.input_each_frame { |frame| EAT_THEN_WAIT.fetch(frame, []) }.run(program, frames: 200)

    assert_operator played[:eaten], :>=, 1, "the waka should be in the run compared"
    assert_operator played[:caught], :>=, 1, "and so should the catch"
    assert_native_sounds_like_the_console program, frames: 200, buttons: EAT_THEN_WAIT, voices: [:square2]
  end
end
