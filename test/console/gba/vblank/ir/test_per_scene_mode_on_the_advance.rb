# frozen_string_literal: true

require "test_helper"

# The tests of test_per_scene_mode.rb whose games turn or resize a background, which a Game Boy
# Color's hardware cannot do, so they play on the Advance's runs alone. The same game read off
# the Advance's cartridge in the emulator is in
# test/lowering/gba/vblank/ir/test_per_scene_mode_on_the_advance_cartridge.rb.

# The game both files play.
module PerSceneModeOnTheAdvanceGames
  # FROM A PAINTED PICTURE TO A TURNING ONE, the whole display changes: the console stops
  # showing the bitmap the title painted the moment the rotozoom screen takes over, so where
  # the new scene draws nothing, what shows is the backdrop — not the title's red.
  private def rotozoom_after_a_bitmap_title
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      var :state, 0
      scene :title do
        clear_screen :red
        pressed(:start).then { set! :state, 1 }
      end
      scene :spin do
        screen :rotozoom
        draw_text "HI", 100, 70, :white
      end
      game_loop do
        wait_vblank
        case_var(:state) { when_val 0, :title; when_val 1, :spin }
      end
    end
    b.finalize_program
    b.program
  end

  # The game pressed START on its second frame and played to its eighth.
  private def spun_after_start
    game_player.input_each_frame { |f| f == 2 ? [:start] : [] }.run(rotozoom_after_a_bitmap_title, frames: 8)
  end
end

class TestPerSceneModeOnTheAdvance < Minitest::Test
  include PerSceneModeOnTheAdvanceGames

  def test_a_bitmap_title_is_gone_once_a_rotozoom_scene_takes_over
    red = Color.resolve(:red)
    title = game_player.run(rotozoom_after_a_bitmap_title, frames: 4)
    assert_equal red, title.screen.pixel(0, 0), "the title is up"

    spun = spun_after_start
    refute_equal red, spun.screen.pixel(0, 0), "the interpreter leaves the title's picture behind"
  end
end
