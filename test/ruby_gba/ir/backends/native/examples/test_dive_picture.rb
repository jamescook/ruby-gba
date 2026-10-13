# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/dive"

# examples/dive built for the desktop shows the interpreter's picture pixel for pixel, frame by
# frame, over a recorded run: the title left alone while its sun turns and its near shafts of
# light step through their four lists of colors; then START, and the diver swum down behind the
# see-through water with the fish in their own colors, until the air is gone, the world fades
# out and the dive ends; then START again, and a new dive. Its variables match on every frame.
class TestDivePicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  # The title for forty frames, START, then down all the way. START is tapped again well after
  # the air has gone, to begin another dive, and the diver swims left in it.
  DIVING = (44..700)
  RUN = Ractor.make_shareable(
    NativeComparison.held_for([DIVING, :down], [741..760, :left])
                    .merge(41 => [:start], 42 => [:start], 720 => [:start], 730 => [:start], 740 => [:start])
  )
  FRAMES = 760

  def test_dive_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Dive::GAME, err: nil)

    # Played once on the interpreter, which mixes five layers in Ruby on every frame of this
    # game, and read below for what the buttons did as well as compared with the C.
    moments = reference_snapshots(program, frames: FRAMES, buttons: RUN)

    assert_native_matches_reference program, frames: FRAMES, buttons: RUN, played: moments

    assert_equal Dive::TITLE, moments[38].variables[:state], "the title should have had its forty frames"
    assert(moments.any? { |moment| moment.variables[:blacking_out] == 1 }, "the air should have run out and the world gone dark")
    assert(moments.any? { |moment| moment.variables[:state] == Dive::OVER }, "and the dive ended")
    assert_equal Dive::PLAY, moments.last.variables[:state], "and START should have begun another"
  end
end
