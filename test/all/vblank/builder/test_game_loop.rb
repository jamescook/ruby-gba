# frozen_string_literal: true

require "test_helper"

# The counting game these tests play, kept once for this file and for the tests of the same
# game on the Advance's cartridge (test/lowering/gba/vblank/builder/test_game_loop_cartridge.rb).
module GameLoopGames
  # Count up once per frame, capped at +count+ so the value settles. Reading it back
  # after enough frames tells us the loop really advanced (and didn't hang) — the same
  # program, the same final value, whether interpreted or run on hardware.
  private def counting_loop(count)
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap
      frames = var :frames, 0
      game_loop do
        (frames < count).then { add! :frames, 1 }
      end
    end
    builder.finalize_program
    builder.program
  end
end

# `game_loop` runs its body once a frame. How the Advance's cartridge waits for the frame —
# the BIOS routine, the interrupt handler, the branch back — and the loop counted on real
# hardware are in test/lowering/gba/vblank/builder/test_game_loop_cartridge.rb.
class TestGameLoop < Minitest::Test
  include GameLoopGames

  def test_the_loop_advances_once_per_frame_on_the_interpreter
    program = counting_loop(20)
    i = game_player.run(program, frames: 30)
    assert_equal 20, i[:frames], "the loop bumps the counter once per frame up to the cap"
  end
end
