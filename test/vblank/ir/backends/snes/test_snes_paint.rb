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

  # A pass that clears the whole screen changes every one of its 896 tiles. Copied whole that is
  # 57344 bytes, fourteen blanks' worth. But a clear writes nothing: the tiles it covers show one
  # tile of the clear colour, so the pass sends that tile, the screen's map and the few tiles the
  # rectangle covers (30 pixels square at a place off the tile edges: five by five tiles, 1600 bytes),
  # all inside one blank. So each pass takes the one frame it takes on the interpreter, and none is
  # black. The checked run holds each pass's picture to the interpreter's; the frames between
  # passes are what only a player sees, read here one by one.
  def test_a_pass_that_clears_and_draws_a_little_takes_one_frame
    program = clear_and_draw_program
    SNES::CheckedRun.new.run(program, frames: 6) # raises if a pass's picture differs from the interpreter's
    run = SNES::HeadlessRun.new(watch_picture: true).run(program, frames: 6)

    assert_empty run.black_frames
    assert_equal [1] * 5, (2..6).map { |pass| run.frames_took(pass) }
  end

  # The same on a cartridge with a Super FX, whose copy of the screen is the chip's RAM.
  def test_a_pass_that_clears_and_draws_a_little_takes_one_frame_on_the_super_fx
    program = clear_and_draw_program.tap { |game| game.variant = :superfx }
    SNES::CheckedRun.new.run(program, frames: 6)
    run = SNES::HeadlessRun.new(watch_picture: true).run(program, frames: 6)

    assert_empty run.black_frames
    assert_equal [1] * 5, (2..6).map { |pass| run.frames_took(pass) }
  end

  # Half the screen painted each pass, the left half and then the right, is 448 tiles (28672
  # bytes) for the blank: seven blanks' worth at least. While they arrive the screen must show the
  # last pass's whole picture, and then this pass's whole picture, never a mix: not half the new
  # tiles (a wipe down the screen), and not the old tiles in the new pass's faded colours.
  def test_a_big_change_and_its_colours_arrive_on_the_same_frame
    program = program_of do
      screen :bitmap
      n = var :n, 0
      game_loop do
        clear_screen :black
        fade :black, (n % 4) * 20
        (n % 2 == 0).then { fill_rect 0, 0, 128, 224, :red }
        (n % 2 == 1).then { fill_rect 128, 0, 128, 224, :green }
        n.add! 1
      end
    end
    SNES::CheckedRun.new.run(program, frames: 5)
    run = SNES::HeadlessRun.new(watch_picture: true).run(program, frames: 5)

    assert_operator run.frames_took(3), :>, 1, "the half screen takes more than one blank"
    assert_empty run.black_frames
    assert_empty run.torn_frames
  end

  # A clear moves the screen on a generation, and a tile painted in an older one is the clear
  # colour. The count is a byte, so it comes round: the 257th clear has the number the first had.
  # The tile painted red after the first clear, and never since, must still be the clear colour then,
  # and the green square painted into it must show on the clear colour.
  def test_a_tile_painted_before_the_generations_come_round_is_cleared_after
    run = checked(frames: 257) do # the run ends on the pass n is 256 in
      screen :bitmap
      n = var :n, 0
      game_loop do
        clear_screen :blue
        (n == 0).then { fill_rect 0, 0, 8, 8, :red }
        (n == 256).then { fill_rect 0, 0, 2, 2, :green }
        n.add! 1
      end
    end

    assert_equal Color.resolve(:green), run.screen.pixel(1, 1)
    assert_equal Color.resolve(:blue), run.screen.pixel(5, 5)
  end

  # THE CAMERA moves the view over the painted picture: screen (0, 0) shows what was painted at the
  # camera's place, and past the picture's edges the backdrop shows, black, faded with the rest. The
  # picture has a different colour along each edge, so a view that wraps round shows one edge's
  # colour where the backdrop should be. The view goes past every edge, and past the picture
  # altogether, from -330 to 326 across (in a shuffled order, so a view far up or down is not
  # always far across too) and -330 to 310 down, and once to 65546 across: far enough that a view
  # not held to the picture's size would come round onto it.
  def test_the_camera_shows_the_backdrop_past_every_edge_of_the_picture
    run = checked(frames: 17) do
      screen :bitmap
      clear_screen :gray
      fill_rect 0, 0, 256, 8, :red        # the top edge
      fill_rect 0, 216, 256, 8, :green    # the bottom edge
      fill_rect 0, 0, 8, 224, :blue       # the left edge
      fill_rect 248, 0, 8, 224, :yellow   # the right edge
      t = var :t, 0
      game_loop do
        camera (((t * 7) % 17) * 41) - 330, (t * 40) - 330
        (t == 16).then { camera 65_546, 3 }
        fade :white, (t % 3) * 25
        t.add! 1
      end
    end

    assert_equal 17, run[:t]
  end

  # Breakout's shake: the camera jolted a few pixels and put back.
  def test_a_shaken_screen_shows_what_the_interpreter_shows
    run = checked(frames: 12) do
      screen :bitmap
      clear_screen :gray
      fill_rect 100, 100, 20, 20, :red
      n = var :n, 0
      game_loop do
        (n == 2).then { shake_screen intensity: 3, frames: 6 }
        n.add! 1
      end
    end

    assert_equal 12, run[:n]
  end

  # A tiled screen's view moves with `scroll_to`; the camera there is refused in plain words, as
  # it is on the Advance.
  def test_the_camera_on_a_tiled_screen_is_refused_in_plain_words
    error = assert_raises(SNES::LoweringError) do
      SNES.new.build(program_of do
        screen :tiled
        game_loop { camera 3, 3 }
      end)
    end

    assert_match(/scroll_to/, error.message)
  end

  # A PAINTED SPRITE moving every pass costs the patch under it put back, the patch at its new place
  # kept, and its picture painted there: a 16×16 picture at a place off the tile edges touches nine
  # tiles. That all fits one frame, as on the interpreter.
  def test_a_painted_sprite_moving_every_pass_keeps_up_with_the_screen
    program = program_of do
      screen :bitmap
      clear_screen rgb(0, 0, 8)
      2.times do |k|
        image(:"coin#{k}", "." => :transparent, "Y" => :yellow, "o" => :orange) do
          Array.new(16) { |row| Array.new(16) { |col| (row + col + k).even? ? "Y" : (col > 2 && col < 13 ? "o" : ".") }.join }.join("\n")
        end
      end
      coin = sprite :coin, at: [37, 41], frames: %i[coin0 coin1], rate: 2
      game_loop { coin.move :right, by: 3 }
    end
    SNES::CheckedRun.new.run(program, frames: 10)
    run = SNES::HeadlessRun.new.run(program, frames: 10)

    assert_equal [1] * 9, (2..10).map { |pass| run.frames_took(pass) }
  end

  # Which pixels of each tile column a painting may touch is worked out once a picture or a patch,
  # and a picture painted inside a narrow area holds its columns to that area. The sprite's patch put
  # back after it, in the same columns, is held to the whole screen again: every pixel it covered.
  def test_a_patch_put_back_after_a_picture_held_to_an_area_puts_back_every_pixel
    run = checked(frames: 12) do
      screen :bitmap
      clear_screen :cyan
      image(:dot, "o" => :red) { "oooooooooooooooo\n" * 4 }
      image(:ball, "." => :transparent, "o" => :white) { "oooooooooooo\n" * 6 }
      ball = sprite :ball, at: [0, 2]
      x = var :x, 0
      game_loop do
        inside(0, 0, 12, 12) { blit :dot, 0, 0 }
        x.add! 2
        ball.move_to x, 2
      end
    end

    assert_equal Color.resolve(:cyan), run.screen.pixel(1, 7)
  end

  private def clear_and_draw_program
    program_of do
      screen :bitmap
      x = var :x, 3
      game_loop do
        clear_screen :blue
        draw_rect_at x, 21, 30, 30, :yellow
        x.add! 7
      end
    end
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
