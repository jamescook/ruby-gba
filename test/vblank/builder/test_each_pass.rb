# frozen_string_literal: true

require "test_helper"

# `each_pass`: a step an effect takes once a pass of the game loop, started and stopped as the
# game says. `start` takes the first step there and then, on the pass that calls it, and the
# rest one a pass after it until `stop` — which is how a game being copied steps its effects, in
# its own passes, however many frames a slow one takes.
class TestEachPass < Minitest::Test
  # A white bitmap room whose loop counts its turns and runs +each+ after the count; +before+
  # runs before the loop. Read at the end of each turn: the steps taken and the turn.
  private def steps_by_turn(frames, before: nil, &each)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      var :steps, 0
      turn = var :turn, 0
      instance_exec(&before) if before
      game_loop do
        turn.add! 1
        instance_exec(turn, &each)
      end
    end
    b.finalize_program
    seen = []
    run = game_player
    run.each_vblank { seen << run[:steps] }
    run.run(b.program, frames: frames)
    seen # the first is read before turn 1, so turn n's end is at n
  end

  # A step that counts itself and stops after four.
  private def counting = lambda {
    steps = var :steps, 0
    each_pass(:counting) do |job|
      steps.add! 1
      (steps == 4).then { job.stop }
    end
  }

  def test_start_takes_a_step_on_its_own_pass_and_one_a_pass_until_stop
    seen = steps_by_turn(10, before: counting) { |turn| (turn == 3).then { each_pass(:counting).start } }

    assert_equal [0, 0, 0, 1, 2, 3, 4, 4, 4, 4], seen
  end

  def test_starting_a_running_step_does_nothing
    seen = steps_by_turn(6, before: counting) { |turn| ((turn >= 2) & (turn <= 4)).then { each_pass(:counting).start } }

    assert_equal [0, 0, 1, 2, 3, 4], seen
  end

  # A step that stops its own job and starts it again keeps running, and takes its next step on
  # the next pass rather than again at once.
  def test_a_step_that_restarts_its_own_job_takes_its_next_step_next_pass
    restarting = lambda {
      steps = var :steps, 0
      each_pass(:restarting) do |job|
        steps.add! 1
        job.stop
        job.start
      end
    }
    seen = steps_by_turn(6, before: restarting) { |turn| (turn == 2).then { each_pass(:restarting).start } }

    assert_equal [0, 0, 1, 2, 3, 4], seen
  end

  # A pass that takes three frames takes one step, where `once_a_frame` would take three.
  def test_a_slow_pass_takes_one_step
    skip_on_native "makes a pass take several frames with `frames_each_pass`, which only the interpreter can"
    skip_on_js "makes a pass take several frames with `frames_each_pass`, which only the interpreter can"
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

  def test_each_pass_needs_a_block_to_make_a_step
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { each_pass } }

    assert_match(/needs a block/, error.message)
  end

  def test_a_step_named_twice_is_refused
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        each_pass(:walk) {}
        each_pass(:walk) {}
      end
    end

    assert_match(/each_pass :walk/, error.message)
  end

  def test_asking_for_a_step_that_is_not_there_says_so
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { each_pass(:walk) } }

    assert_match(/no `each_pass :walk`/, error.message)
  end
end
