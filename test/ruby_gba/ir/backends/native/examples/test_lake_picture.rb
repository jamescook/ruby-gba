# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/lake"

# examples/lake.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, for longer than two whole waves take to roll down the water: every row of the water
# at its own place across, and three half see-through jellyfish drifting over it, two of them
# off the right edge and back in at the left.
class TestLakePicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  FRAMES = 140
  GLINT = RubyGBA::Graphics::Color.rgb(28, 27, 17) # the brightest color of the sun's reflection

  # The lake reads no buttons, so there is no run of them to record: it is left alone.
  def test_lake_matches_the_interpreter_through_two_waves
    program = Native.new.checked_program(Lake::GAME, err: nil)
    moments = reference_snapshots(program, frames: FRAMES, buttons: {})

    assert_native_matches_reference(program, frames: FRAMES)

    # The sun's reflection is drawn as a straight pillar, so where its brightest color starts
    # on each row of the water says how far across that row sits.
    snake = ->(moment) { moment.picture.each_slice(WIDTH).map { |row| row.index(GLINT) } }
    now = snake.call(moments.last)
    a_quarter_wave_ago = snake.call(moments[-1 - (Lake::WAVE_ROWS / 4)])
    rows_moved = now.zip(a_quarter_wave_ago).count { |here, there| here && there && here != there }

    assert_operator now.compact.uniq.length, :>=, 2 * Lake::SWAY, "the pillar should snake from side to side"
    # More rows than three jellyfish drifting over the pillar could account for.
    assert_operator rows_moved, :>=, 50, "and the snake should travel down the water"
    across = moments.map { |moment| moment.variables.values_at(:__obj2_x, :__obj3_x) }.transpose

    assert(across.all? { |places| places.each_cons(2).any? { |before, after| after < before } },
           "two of the jellyfish should have left at the right and come back in at the left")
  end
end
