# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/pong"

# examples/pong.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, over a recorded run: the zooming title and its menu, START, the zoom away, and a
# rally with the paddle moved up and down. Its sound log — the song, the beeps — matches entry
# for entry too; what comes out of the speaker is test_pong_sounds.rb's.
class TestPongPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  # The buttons held, frame by frame: down and up on the title's menu, A on START, then the
  # paddle up and down once the rally is under way.
  RUN = Ractor.make_shareable(
    { 20 => %i[down], 24 => %i[up], 30 => %i[a] }
      .merge((100..125).to_h { |frame| [frame, %i[up]] })
      .merge((126..160).to_h { |frame| [frame, %i[down]] })
  )

  def test_pong_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(PongGame::GAME, err: nil)

    last = assert_native_matches_reference(program, frames: 160, buttons: RUN)

    assert_equal 1, last.variables[:state], "the run should end in the rally"
    assert(last.sounds.any? { |entry| entry.first == :note }, "the rally's song should be in the log compared")
  end
end
