# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/bird").to_s

# examples/bird.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, through a flight: right, then a climb with the nose tipped up, a dive with it tipped
# down, and level again, while the bird drifts nearer and further the whole time.
class TestBirdPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  FLIGHT = Ractor.make_shareable(
    NativeComparison.held_for([2..25, :right], [26..50, :up], [51..90, :down], [91..110, :left])
  )
  # One drift from furthest to nearest and back is two and a half seconds, 150 frames: this is
  # all the way to its nearest and most of the way back.
  FRAMES = 120

  def test_bird_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Bird::GAME, err: nil)
    moments = reference_snapshots(program, frames: FRAMES, buttons: FLIGHT)
    tilts = moments.map { |moment| moment.variables.fetch(:__obj1_angle) }
    sizes = moments.map { |moment| moment.variables.fetch(:__obj1_scale) }

    assert_recorded_run_matches_reference(program, frames: FRAMES, buttons: FLIGHT)

    assert_equal [0, 335, 25, 0], tilts.chunk_while { |a, b| a == b }.map(&:first),
                 "level, nose up for the climb, nose down for the dive, level again"
    one = RubyGBA::IR::Build::SCALE_ONE
    assert_operator sizes.min, :<, one * 0.8, "it should have been drawn well under its own size"
    assert_operator sizes.max, :>, one * 1.2, "and well over it"
  end
end
