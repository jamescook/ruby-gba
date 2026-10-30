# frozen_string_literal: true

require "test_helper"

# The game these tests play, kept once for the interpreter's own tests
# (test/interpreter/vblank/builder/test_frames_since_power_on_interpreter.rb) and the Advance's
# cartridge's (test/lowering/gba/vblank/builder/test_frames_since_power_on_cartridge.rb).
module FramesSincePowerOnGames
  include SharedConstants

  # A bitmap room that spins +busy+ times before its loop, then notes what the reading was on its
  # first pass and what it is on every pass.
  private def counting_game(busy = 0)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      spin = var :spin, 0
      passes = var :passes, 0
      first = var :first, -1
      now = var :now, -1
      repeat(busy) { spin.add! 1 } if busy.positive?
      game_loop do
        (passes == 0).then { first.set! frames_since_power_on }
        now.set! frames_since_power_on
        passes.add! 1
      end
    end
    b.finalize_program
    b.program
  end
end

# `frames_since_power_on`: how many frames the screen has shown since the power came on, setting
# up included — so a screen held until it reaches a number ends on that frame however long the
# game took to set up.
class TestFramesSincePowerOn < Minitest::Test
  include FramesSincePowerOnGames

  def test_each_pass_of_a_game_that_keeps_up_reads_one_more_frame
    seen = []
    run = game_player
    run.each_vblank { seen << run[:now] }
    run.run(counting_game, frames: 5)

    assert_equal(-1, seen.first) # read before the first pass
    # The first pass reads the frames setting up took, one or more; each after it one more.
    assert_operator seen[1], :>=, 1
    assert_equal (seen[1]..(seen[1] + 3)).to_a, seen.drop(1)
  end

  # A pass told to take several frames, and frames spent setting up with the screen off, are the
  # interpreter's to be told: test/interpreter/vblank/builder/test_frames_since_power_on_interpreter.rb.
  # The console counting the frames it spent setting up is
  # test/lowering/gba/vblank/builder/test_frames_since_power_on_cartridge.rb.
end
