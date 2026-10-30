# frozen_string_literal: true

require "test_helper"

# The picture check playing a Color cartridge beside the interpreter, which it does only on the
# interpreter's run: every other run compares its own lowered game instead. How a difference is
# reported is in test/all/vblank/testing/test_pictures_on_each_console.rb.
class TestPicturesOnEachConsoleInterpreter < Minitest::Test
  include VBlank::Testing::Pictures

  COLOR = VBlank::Console::COLOR

  def test_a_color_program_is_compared_as_a_color_cartridge
    program = boxes(:gbc)
    oracle, console, = backend_pictures(program, frames: 4)

    assert_equal COLOR.screen_width * COLOR.screen_height, console.size, "the Color's screen"
    assert_equal Color.resolve(:blue), pixel_at(console, 150, 134), "the Color's bottom right corner"
    assert_empty mismatched_pixels(oracle, console)
  end

  # Each pass moves the box, so only the right pairing of the Color's frames with the
  # interpreter's agrees, on a painted screen and on a tiled one — and it is at the frame asked
  # for, so the Color's start-up frames are what Pictures::LINE_UPS says.
  def test_a_moving_color_picture_lines_up_at_the_frame_asked_for
    asked = [2, 5]
    [boxes(:gbc), walker(:gbc)].each do |program|
      asked.each do |frame|
        oracle, console, ran = backend_pictures(program, frames: frame)

        assert_equal frame, ran, program.walk.find { |node| node.kind == :screen }.mode
        assert_empty mismatched_pixels(oracle, console)
      end
    end
  end

  private def boxes(console)
    VBlank.game("BOXES", consoles: [console]) do
      screen :bitmap
      x = var :x, 8
      game_loop do
        clear_screen :white
        draw_rect_at x, 8, 8, 8, :red
        draw_rect_at 144, 128, 16, 16, :blue
        x.add! 4
      end
    end.program
  end

  private def walker(console)
    VBlank.game("WALKER", consoles: [console]) do
      screen :tiled
      image(:box, "#" => :red) { Array.new(8) { "#" * 8 }.join("\n") }
      hero = sprite :box, at: [0, 20]
      game_loop { hero.x.add! 4 }
    end.program
  end
end
