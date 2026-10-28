# frozen_string_literal: true

require "test_helper"

# What a Super Nintendo cartridge paints on a painted (bitmap) screen is what the interpreter
# paints, pixel for pixel, after every pass (SNES::CheckedRun). Places and sizes are picked off the
# console's 8-pixel tile edges, and pictures are placed at every place across modulo eight, so a
# pixel shifted into the wrong tile, a mask a pixel short or a plane written to the wrong byte
# shows as a pixel in the wrong place.
class TestSNESPaint < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  def test_rectangles_and_pixels_off_the_tile_edges
    run = checked(frames: 6) do
      screen :bitmap
      clear_screen :blue
      fill_rect 3, 5, 1, 9, :red        # one column inside a tile
      fill_rect 6, 2, 13, 4, :yellow    # across three tiles
      fill_rect 250, 218, 20, 20, :green # off the right and bottom edges
      fill_rect(-5, -3, 9, 6, :white)   # off the left and top
      x = var :x, 17
      game_loop do
        draw_rect_at x, 40, 1, 1, :magenta
        draw_rect_at x, 60, x / 4, 3, rgb(10, 20, 30)
        x.add! 5
      end
    end

    assert_equal Color.resolve(:red), run.screen.pixel(3, 5)
    assert_equal Color.resolve(:blue), run.screen.pixel(4, 5)
  end

  def test_clearing_inside_an_area_and_drawing_held_to_it
    run = checked(frames: 4) do
      screen :bitmap
      clear_screen :gray
      inside 13, 9, 30, 21 do
        clear_screen :blue
        fill_rect 0, 0, 100, 12, :orange
      end
      fill_rect 50, 50, 4, 4, :green # outside again: anywhere
      game_loop {}
    end

    assert_equal Color.resolve(:orange), run.screen.pixel(13, 9)
    assert_equal Color.resolve(:gray), run.screen.pixel(12, 9)
    assert_equal Color.resolve(:green), run.screen.pixel(51, 51)
  end

  def test_a_picture_at_every_place_across_and_off_every_edge
    run = checked(frames: 20) do
      screen :bitmap
      image :gem, "." => :transparent, "r" => :red, "g" => :green, "b" => :blue, "w" => :white do
        <<~ART
          ..rrrrgggg..
          .r........g.
          rr..wwww..gg
          b..........b
          .bbbbbbbbbb.
        ART
      end
      x = var :x, -6
      game_loop do
        clear_screen :black
        blit :gem, x, 7 + x
        blit :gem, 250 - x, 220 - x
        blit :gem, x * 3, -2
        x.add! 1
      end
    end

    assert_operator run[:x], :>, 10
  end

  def test_text_and_digits_in_a_picked_colour
    run = checked(frames: 12) do
      screen :bitmap
      n = var :n, 0
      game_loop do
        clear_screen :black
        draw_text "SCORE", 3, 4, :white
        draw_number n, 45, 4, :yellow, digits: 3
        draw_text "GO", 5, 30, %i[red green], showing: n % 2 == 1
        n.add! 7
      end
    end

    assert_equal 84, run[:n], "twelve passes"
  end

  def test_a_sprite_moving_over_a_painted_room_puts_back_what_it_covered
    run = checked(frames: 30) do
      screen :bitmap
      clear_screen :cyan
      fill_rect 40, 20, 30, 30, :orange
      image :ball, "." => :transparent, "o" => :white do
        ".oo.\noooo\noooo\n.oo.\n"
      end
      ball = sprite :ball, at: [30, 30]
      x = var :x, 30
      game_loop do
        x.add! 3
        ball.move_to x, 30 + (x / 8)
      end
    end

    assert_equal Color.resolve(:orange), run.screen.pixel(41, 21)
  end

  # A pass that clears the whole screen changes every one of its 896 tiles, 56K, far more than a
  # blank has time to copy. It reaches the screen over several frames, and none of them is black:
  # the screen is never switched off for it. The checked run holds each pass's picture to the
  # interpreter's; the frames between passes are what only a player sees, read here one by one.
  # A blank copies 4096 bytes at most, so the 57344 bytes of the screen take 14 blanks, and the
  # pass is shown on the frame after its last: no pass takes more than 15 frames.
  def test_a_pass_that_changes_the_whole_screen_shows_no_black_frame
    program = program_of do
      screen :bitmap
      x = var :x, 0
      game_loop do
        clear_screen :blue
        draw_rect_at x, 20, 30, 30, :yellow
        x.add! 7
      end
    end
    SNES::CheckedRun.new.run(program, frames: 4)
    run = SNES::HeadlessRun.new(watch_picture: true).run(program, frames: 4)

    assert_empty run.black_frames
    assert_operator (2..4).map { |pass| run.frames_took(pass) }.max, :<=, (57_344 / 4096) + 1
  end

  private def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :snes }
  end

  private def checked(frames:, &game)
    SNES::CheckedRun.new.run(program_of(&game), frames: frames)
  end
end
