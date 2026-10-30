# frozen_string_literal: true

require "test_helper"

# The tests of test_per_scene_mode.rb whose games turn or resize a background, which a Game Boy
# Color's hardware cannot do, so they play on the Advance's runs alone.
class TestPerSceneModeOnTheAdvance < Minitest::Test
  include VBlank::Console::Hardware

  # FROM A PAINTED PICTURE TO A TURNING ONE, the whole display changes: the console stops
  # showing the bitmap the title painted the moment the rotozoom screen takes over, so where
  # the new scene draws nothing, what shows is the backdrop — not the title's red.
  private def rotozoom_after_a_bitmap_title
    b = Builder.new
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

  def test_a_bitmap_title_is_gone_once_a_rotozoom_scene_takes_over
    red = Color.resolve(:red)
    title = game_player.run(rotozoom_after_a_bitmap_title, frames: 4)
    assert_equal red, title.screen.pixel(0, 0), "the title is up"

    spun = game_player.input_each_frame { |f| f == 2 ? [:start] : [] }.run(rotozoom_after_a_bitmap_title, frames: 8)
    refute_equal red, spun.screen.pixel(0, 0), "the interpreter leaves the title's picture behind"

    rom = assemble_rom(rotozoom_after_a_bitmap_title, name: "SPINOVER")
    v = assert_emulator_loads_rom(rom, frames: 10, keys: ->(f) { f == 3 ? KEY_START : 0 })
    refute v.red?(0, 0), "the console leaves it behind, got 0x#{format('%04X', v.pixel_gba(0, 0))}"
    assert_equal v.pixel_gba(0, 0), spun.screen.pixel(0, 0), "and both show the same thing there"
  end
end
