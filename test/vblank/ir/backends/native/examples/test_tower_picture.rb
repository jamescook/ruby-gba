# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require VBlank.root.join("examples/tower").to_s

# examples/tower.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, while the hero climbs all three floors and opens the gate on the roof. Each floor is a
# scene with a :floor of its own, so a floor brought up wrong, or its walls left from the floor
# below, shows as a wrong picture or the hero a cell out.
class TestTowerPicture < Minitest::Test
  include NativeComparison

  # The ground floor's stairs (right, then up), upstairs' (up, right, up), then the roof: right to
  # the wall under the gate, up toward it, and A to open it. Each leg is held past the wall that
  # stops the hero, so the walls decide where he ends up.
  CLIMB = Ractor.make_shareable(
    NativeComparison.held_for([1..70, :right], [71..132, :up], [139..180, :up], [181..250, :right],
                              [251..280, :up], [287..326, :right], [327..388, :up], [392..394, :a])
  )

  def test_tower_matches_the_interpreter_up_every_floor
    program = Native.new.checked_program(Tower::GAME, err: nil)

    assert_recorded_run_matches_reference program, frames: 400, buttons: CLIMB
  end
end
