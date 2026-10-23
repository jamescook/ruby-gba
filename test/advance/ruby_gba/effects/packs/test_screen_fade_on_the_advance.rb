# frozen_string_literal: true

require "test_helper"

# THE TESTS OF ruby_gba/effects/packs/test_screen_fade.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so
# that the Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# The Advance's display fades a plain bitmap screen itself, in sixteenths. A Game Boy Color has no
# display blend, so every fade there walks the colours, in thirty-seconds.
class TestScreenFadeOnTheAdvance < Minitest::Test
  # The display's own fade counts in sixteenths, so a plain bitmap screen, which has no
  # colour table to walk, keeps the old steps. It is the yardstick for the finer steps a
  # screen drawn through a colour table takes (TestScreenFade).
  def test_a_long_fade_on_a_plain_bitmap_screen_keeps_seventeen_steps
    assert_equal 17, ramp(long_fade, 50).uniq.size
  end

  private

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A red bitmap screen that fades up to white over 33 frames from frame 2, and back from frame 50.
  def long_fade
    program do
      screen :bitmap
      frame = var :frame, 0
      game_loop do
        clear_screen :red
        frame.add! 1
        (frame == 2).then { fade_out :white, frames: 33 }
        (frame == 50).then { fade_in }
      end
    end
  end

  # The colour at one spot on each of the first +frames+ frames, read from one run as each frame
  # settles; the look at the boundary before the first pass is dropped.
  def ramp(prog, frames)
    seen = []
    run = game_player
    run.each_vblank { seen << run.screen.pixel(120, 80) }
    run.run(prog, frames: frames + 1)
    seen.drop(1).first(frames)
  end
end
