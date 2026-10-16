# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/sparks").to_s

# examples/sparks.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, for long enough that every slot of its pool of sparks has been used and, for most of
# the run, the oldest is being given up for each new one. Which spark is the oldest is the order
# they are kept in, so a pool that kept it wrongly shows as the wrong spark gone.
class TestSparksPicture < Minitest::Test
  include NativeComparison

  def test_sparks_matches_the_interpreter_once_the_pool_is_full
    program = Native.new.checked_program(Sparks::GAME, err: nil)

    last = assert_native_matches_reference(program, frames: Sparks::SLOTS * 4)

    assert_includes last.picture, Color.resolve(:yellow), "sparks should be in the last picture compared"
  end
end
