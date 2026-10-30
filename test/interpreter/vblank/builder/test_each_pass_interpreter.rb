# frozen_string_literal: true

require "test_helper"

# `each_pass` in a pass told to take several frames, which only the interpreter can be told
# (`frames_each_pass`). The rest of the verb's tests, played on every run, are in
# test/all/vblank/builder/test_each_pass.rb.
class TestEachPassInterpreter < Minitest::Test
  # A pass that takes three frames takes one step, where `once_a_frame` would take three.
  def test_a_slow_pass_takes_one_step
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      steps = var :steps, 0
      job = each_pass { steps.add! 1 }
      job.start
      game_loop {}
    end
    b.finalize_program
    run = game_player.frames_each_pass { 3 }.run(b.program, frames: 4)

    assert_equal 5, run[:steps], "one step as it starts, and one for each of four passes"
  end
end
