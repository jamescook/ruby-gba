# frozen_string_literal: true

require "test_helper"

# The test of test_camera_shake.rb that reads the Advance's own screen: a pixel near the right
# edge of its 240 columns, past the end of the Game Boy Color's 160, so it plays on the Advance's
# runs alone.
class TestCameraShakeOnTheAdvance < Minitest::Test
  BLUE = RubyGBA::Graphics::Color.resolve(:blue)

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  def test_a_window_pushed_off_the_picture_shows_the_backdrop
    prog = program do
      screen :bitmap
      clear_screen :blue
      camera 10, 0
      halt
    end
    i = game_player.run(prog)

    assert_equal 0, i.screen.pixel(235, 80), "past the drawn picture there is nothing to show"
    assert_equal BLUE, i.screen.pixel(0, 80), "inside it, the drawing still shows"
  end
end
