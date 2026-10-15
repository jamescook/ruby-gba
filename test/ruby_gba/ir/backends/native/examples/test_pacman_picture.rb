# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/pacman").to_s

# examples/pacman.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, over a recorded run: Pac walked up into a pellet and along the room, then left alone
# until the ghost catches him and he blinks white. Its variables and its sound log match on every
# frame too.
class TestPacmanPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  # Up into the pellet above him, left along the room, down and right again, then nothing held.
  RUN = Ractor.make_shareable(
    NativeComparison.held_for([2..30, :up], [31..60, :left], [61..75, :down], [76..90, :right])
  )

  def test_pacman_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Pacman::GAME, err: nil)

    last = assert_native_matches_reference(program, frames: 260, buttons: RUN)

    assert_operator last.variables[:eaten], :>=, 1, "the run should eat a pellet"
    assert_operator last.variables[:caught], :>=, 1, "and the ghost should catch him once he stands still"
    assert_equal [[:enabled]], last.sounds.first(1), "the sound log compared should start with the sound switched on"
    assert_operator last.sounds.count { |entry| entry.first == :beep }, :>=, 2, "with the waka and the catch in it"
  end
end
