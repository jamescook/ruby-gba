# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/parallax").to_s

# examples/parallax.rb built for the desktop shows the interpreter's picture pixel for pixel,
# frame by frame, while its two layers slide at their own speeds: right for a second, then left
# for longer, so both pass back through where they started and on below nought.
class TestParallaxPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  SLIDE = Ractor.make_shareable(NativeComparison.held_for([2..60, :right], [61..150, :left]))

  def test_parallax_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Parallax::GAME, err: nil)

    last = assert_recorded_run_matches_reference(program, frames: 160, buttons: SLIDE)

    assert_equal [-31, -62], last.variables.values_at(:__bg_sky_sx, :__bg_ground_sx),
                 "the near layer should have gone twice as far as the far one"
  end
end
