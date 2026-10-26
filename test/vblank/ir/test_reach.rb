# frozen_string_literal: true

require "test_helper"

# WHAT A RUN OF A PROGRAM CAN REACH (IR::Reach): the routines it calls, however deep, and the
# variables it keeps. Every lowering asks, so each makes the same routines and keeps the same
# variables, and a routine nothing calls is made by none of them.
class TestReach < Minitest::Test
  include VBlank::IR::Build

  Reach = VBlank::IR::Reach
  Frames = VBlank::IR::Frames

  def test_routines_reached_by_call_scene_and_number_and_none_other
    program = program(
      func(:deep, set(:d, 1)),
      func(:called, call(:deep)),
      func(:title, set(:t, 1)),
      func(:picked, set(:p, 1)),
      func(:never, set(:n, 1)),
      call(:called),
      case_(:state, [[0, :title]]),
      call_one_of([:picked], which: int(0))
    )

    assert_equal %i[deep called title picked], Reach.routines(program)
  end

  def test_variables_are_frame_counters_then_each_in_order_first_named
    program = program(set(:b, 1), add(:a, var_ref(:c)), repeat(int(2), :i), copy(:e, :b))

    assert_equal [Frames::COUNT, Frames::SEEN, Frames::STEP, :b, :a, :c, :i, :e], Reach.variables(program)
  end
end
