# frozen_string_literal: true

require "test_helper"

# The picture check plays the cartridge of the console the program is built for: a program
# built for the Game Boy Color is played as a Color cartridge, on the Color's smaller screen,
# and its picture held to the interpreter's pixel for pixel, the same as an Advance program's.
class TestPicturesOnEachConsole < Minitest::Test
  include VBlank::Testing::Pictures

  COLOR = VBlank::Console::COLOR

  def test_a_color_program_is_compared_as_a_color_cartridge
    skip "a checked run compares the lowered game, not a cartridge" if VBlank::Testing.checked?

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
    skip "a checked run compares the lowered game, not a cartridge" if VBlank::Testing.checked?

    [boxes(:gbc), walker(:gbc)].each do |program|
      [2, 5].each do |frame|
        oracle, console, ran = backend_pictures(program, frames: frame)

        assert_equal frame, ran, program.walk.find { |node| node.kind == :screen }.mode
        assert_empty mismatched_pixels(oracle, console)
      end
    end
  end

  # A Color picture that differs says where on the Color's screen, in a map of the whole of it.
  def test_a_difference_on_the_colors_screen_is_mapped_over_that_screen
    width = COLOR.screen_width
    oracle = Array.new(width * COLOR.screen_height, 0)
    console = oracle.dup
    console[((COLOR.screen_height - 1) * width) + width - 1] = Color.resolve(:red)

    report = mismatch_message(mismatched_pixels(oracle, console), 4, 6, picture: oracle)

    assert_match(/1 of 23040 pixels differ/, report)
    map = report.lines.grep(/^ {4}[.#]+$/)
    assert_equal [40, 18], [map.first.strip.length, map.size]
    assert map.last.strip.end_with?("#"), "the last row's last cell"
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
