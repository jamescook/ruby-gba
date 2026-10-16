# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require "checked_native_run"
require RubyGBA.root.join("examples/piano").to_s

# examples/piano.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, while both hands play — and mixes the same bytes of sound, slice for slice, with the
# melody note and the left hand's two-note chord sounding together on each downbeat.
class TestPianoPicture < Minitest::Test
  include NativeComparison

  # Two seconds: the tune's first bars, with a chord on every downbeat.
  FRAMES = 120

  def test_piano_matches_the_interpreter_while_both_hands_play
    program = Native.new.checked_program(Piano::GAME, err: nil)

    assert_native_matches_reference(program, frames: FRAMES)
    assert_operator different_pictures_in(program, frames: FRAMES), :>, 1, "the hands should move"
  end

  def test_piano_mixes_the_interpreters_sound
    program = Native.new.checked_program(Piano::GAME, err: nil)
    played = CheckedNativeRun.new.run(program, frames: FRAMES)

    assert_operator played.peak_voices, :>=, 3, "a downbeat sounds the melody and a two-note chord at once"
    assert(played.mixed_sound.any? { |slice| slice.any?(&:nonzero?) }, "the tune should be heard")
  end
end
