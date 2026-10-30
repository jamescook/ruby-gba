# frozen_string_literal: true

require "test_helper"

# A painted screen on a Game Boy Color is 360 tiles the runtime keeps in work memory and sends to
# the console between passes (GBC::Runtime::Paint). Each test is a small painted program played as
# a Color cartridge and checked against the interpreter after every pass (GBC::CheckedRun), so a
# picture that differs anywhere fails it, besides what it asserts.
class TestGBCPaint < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  # A clear in a new colour turns every cell not showing its own tile that colour, and a tile painted
  # after it in the same pass is sent as its own picture as well: the pass's list must hold both.
  def test_a_rectangle_painted_after_a_clear_in_a_new_colour_shows
    run = checked(frames: 2) do
      screen :bitmap
      clear_screen :blue
      draw_rect_at 100, 40, 2, 2, :red
      halt
    end

    assert_equal VBlank::Graphics::Color.resolve(:red), run.screen.pixel(100, 40)
    assert_equal VBlank::Graphics::Color.resolve(:blue), run.screen.pixel(0, 0)
  end

  # A clear in a new colour is the clear tile rewritten, one entry for the whole screen: with the
  # screen already on, a game that clears in another colour every pass takes a frame a pass.
  def test_a_clear_in_a_new_colour_every_pass_takes_a_frame_a_pass
    run = checked(frames: 6) do
      screen :bitmap
      n = var :n, 0
      game_loop do
        n.add! 1
        (n % 2 == 0).then { clear_screen :blue }.else { clear_screen :red }
      end
    end

    assert_equal [1] * 5, (2..6).map { |pass| run.frames_took(pass) }
  end

  # A picture of two colours, put down at a place worked out as the game runs, across the edge
  # between two tiles: each colour lands where it was drawn, and a see-through pixel leaves the
  # screen as it was.
  def test_picture_put_down_at_run_time_place_keeps_its_colours_and_see_through
    run = checked(frames: 2) do
      screen :bitmap
      image :flag, "." => :transparent, "r" => :red, "g" => :green do
        <<~ART
          r.g
          ggr
        ART
      end
      var :x, 6
      clear_screen :blue
      blit :flag, :x, 30
      halt
    end

    red = VBlank::Graphics::Color.resolve(:red)
    green = VBlank::Graphics::Color.resolve(:green)
    assert_equal [red, VBlank::Graphics::Color.resolve(:blue), green], (6..8).map { |x| run.screen.pixel(x, 30) }
    assert_equal [green, green, red], (6..8).map { |x| run.screen.pixel(x, 31) }
  end

  # One of several pictures, picked by a number worked out as the game runs: the one it names
  # goes down, and the others do not.
  def test_picture_picked_by_number_is_the_one_put_down
    run = checked(frames: 2) do
      screen :bitmap
      image :wide, "." => :transparent, "r" => :red do
        "rr\n..\n"
      end
      image :tall, "." => :transparent, "g" => :green do
        "g.\ng.\n"
      end
      var :which, 1
      clear_screen :blue
      blit %i[wide tall], 20, 20, showing: :which
      halt
    end

    assert_equal VBlank::Graphics::Color.resolve(:green), run.screen.pixel(20, 21)
    assert_equal VBlank::Graphics::Color.resolve(:blue), run.screen.pixel(21, 20)
  end

  # A rectangle bigger than the area it is drawn inside paints the area alone, to the pixel,
  # where the area's edges are not a tile's.
  def test_rectangle_drawn_inside_area_paints_only_that_area
    run = checked(frames: 2) do
      screen :bitmap
      clear_screen :blue
      inside 13, 10, 6, 4 do
        draw_rect_at 0, 0, 100, 100, :red
      end
      halt
    end

    red = VBlank::Graphics::Color.resolve(:red)
    blue = VBlank::Graphics::Color.resolve(:blue)
    assert_equal [blue, red, red, blue], [12, 13, 18, 19].map { |x| run.screen.pixel(x, 10) }
    assert_equal [blue, red, blue], [9, 10, 14].map { |y| run.screen.pixel(13, y) }
  end

  # A picture put down across the edges of the area it is drawn inside shows only the part
  # within them, to the pixel.
  def test_picture_put_down_inside_area_shows_only_within_it
    run = checked(frames: 2) do
      screen :bitmap
      image :bar, "r" => :red do
        "#{'r' * 20}\n" * 3
      end
      var :x, 2
      clear_screen :blue
      inside 9, 11, 5, 1 do
        blit :bar, :x, 10
      end
      halt
    end

    red = VBlank::Graphics::Color.resolve(:red)
    blue = VBlank::Graphics::Color.resolve(:blue)
    assert_equal [blue, red, red, blue], [8, 9, 13, 14].map { |x| run.screen.pixel(x, 11) }
    assert_equal [blue, blue], [10, 12].map { |y| run.screen.pixel(10, y) }
  end

  # A clear inside an area is the area alone in that colour; the screen past it, and what is
  # painted after the area ends, are as they would be without it.
  def test_clear_inside_area_paints_only_that_area
    run = checked(frames: 2) do
      screen :bitmap
      clear_screen :blue
      inside 3, 5, 10, 2 do
        clear_screen :red
      end
      draw_rect_at 30, 30, 2, 2, :red
      halt
    end

    red = VBlank::Graphics::Color.resolve(:red)
    blue = VBlank::Graphics::Color.resolve(:blue)
    assert_equal [blue, red, red, blue], [2, 3, 12, 13].map { |x| run.screen.pixel(x, 6) }
    assert_equal [blue, red], [[3, 7], [30, 30]].map { |x, y| run.screen.pixel(x, y) }
  end

  # One column of a picture stretched to a height worked out as the game runs, its top above
  # the screen: each row of the screen shows the picture's row the stretch lands there, and a
  # see-through row leaves the screen as it was.
  def test_column_stretched_to_run_time_height_shows_each_row_where_it_lands
    run = checked(frames: 2) do
      screen :bitmap
      image :wall, "." => :transparent, "r" => :red, "g" => :green do
        "gr\ngr\ng.\ngg\n"
      end
      var :slice, 1
      var :tall, 16
      var :top, -2
      clear_screen :blue
      draw_column_at :wall, slice: :slice, x: 21, top: :top, height: :tall, width: 3
      halt
    end

    red = VBlank::Graphics::Color.resolve(:red)
    blue = VBlank::Graphics::Color.resolve(:blue)
    assert_equal [red, red, blue, VBlank::Graphics::Color.resolve(:green)], [0, 5, 6, 10].map { |y| run.screen.pixel(22, y) }
    assert_equal [blue, red, blue], [20, 23, 24].map { |x| run.screen.pixel(x, 0) }
  end

  # The pixels under a patch, saved and then painted back over what covered them: the patch
  # spans a tile only cleared and a tile painted since, and comes back as it was in both.
  def test_patch_saved_then_put_back_is_as_it_was
    run = checked(frames: 2) do
      screen :bitmap
      clear_screen :blue
      draw_rect_at 9, 5, 2, 2, :red
      record_statement VBlank::IR::Build.backing_buffer(:under, width: 6, height: 4)
      record_statement VBlank::IR::Build.save_region(:under, VBlank::IR::Build.int(5), VBlank::IR::Build.int(4))
      draw_rect_at 5, 4, 6, 4, :green
      record_statement VBlank::IR::Build.restore_region(:under, VBlank::IR::Build.int(5), VBlank::IR::Build.int(4))
      halt
    end

    red = VBlank::Graphics::Color.resolve(:red)
    blue = VBlank::Graphics::Color.resolve(:blue)
    assert_equal [blue, blue, red, red, blue], [5, 8, 9, 10, 11].map { |x| run.screen.pixel(x, 5) }
    assert_equal blue, run.screen.pixel(7, 7)
  end

  private

  def checked(frames:, &game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    program = builder.program
    program.console = :gbc
    GBC::CheckedRun.new.run(program, frames: frames)
  end
end
