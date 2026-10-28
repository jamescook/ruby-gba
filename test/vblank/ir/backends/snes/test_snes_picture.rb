# frozen_string_literal: true

require "test_helper"

# What a Super Nintendo cartridge draws on a tiled screen is what the interpreter draws, pixel for
# pixel, after every pass (SNES::CheckedRun): its backgrounds — put up, scrolled, a cell changed, a
# map handed over — and its sprites, moving, off every edge and back. Colours are picked so that a
# tile drawn from the wrong palette or a sprite one row out shows as a pixel in the wrong place.
class TestSNESPicture < Minitest::Test
  SNES = VBlank::IR::Backends::SNES

  def test_a_sprite_moving_off_every_edge_is_drawn_where_the_interpreter_draws_it
    run = checked(frames: 100) do
      screen :tiled
      image :ship, "." => :transparent, "r" => :red, "g" => :green, "b" => :blue, "w" => :white do
        <<~ART
          rrrrrrrrgggggggg
          r..............g
          r..wwww........g
          r..............g
          bbbbbbbbbbbbbbbb
        ART
      end
      ship = sprite :ship, at: [0, 0]
      x = var :x, -20
      y = var :y, -10
      laps = var :laps, 0
      game_loop do
        x.add! 7
        y.add! 6
        (x > 270).then do
          x.set! -30
          laps.add! 1
        end
        (y > 236).then { y.set! -12 }
        ship.move_to x, y
      end
    end

    assert_operator run[:laps], :>=, 2, "the ship went off the right edge and came back from the left twice"
  end

  # Two backgrounds, the front one see-through in places, and cells changed on both: on the back
  # one's 64×64 map, cells in each of its four 32×32 screens, scrolled into view.
  def test_two_backgrounds_and_cells_in_every_screen_of_a_big_map
    big = "#{(['#' * 64] * 64).join("\n")}\n"
    run = SNES::CheckedRun.new
    run.input_each_frame { |frame| frame == 3 ? [:a] : [] }
       .run(program_of do
         screen :tiled
         image(:wall, "#" => :gray) { "########\n" * 8 }
         image(:hole, "." => :transparent, "o" => :red) { "o......o\n" * 8 }
         image(:gem, "g" => :green) { "gggggggg\n" * 8 }
         tiles :back, "#" => :wall, "g" => :gem
         tiles :front, "o" => :hole, "g" => :gem
         back = background :back, tiles: :back, map: big
         front = background :front, tiles: :front, map: "#{'o' * 32}\n" * 32
         changed = var :changed, 0
         game_loop do
           pressed(:a).then do
             back.set_tile 40, 40, "g"
             back.set_tile 33, 2, "g"
             back.set_tile 2, 35, "g"
             front.set_tile 3, 3, "g"
             changed.set! 1
           end
           back.scroll_to 200, 200
         end
       end, frames: 8)

    assert_equal 1, run[:changed]
  end

  def test_several_sprites_overlap_the_later_one_in_front
    run = checked(frames: 12) do
      screen :tiled
      image(:block, "#" => :yellow) { "########\n" * 8 }
      image(:bar, "#" => :magenta) { "################\n" * 4 }
      a = sprite :block, at: [20, 20]
      b = sprite :bar, at: [16, 22]
      t = var :t, 0
      game_loop do
        t.add! 1
        a.move_to 20 + t, 20
        b.move_to 16 + t, 22
      end
    end

    # The bar, declared second, crosses the block's middle: where they overlap it is the bar's.
    assert_equal Color.resolve(:magenta), run.screen.pixel(34, 23)
  end

  def test_a_background_put_up_scrolled_changed_and_handed_another_map
    run = SNES::CheckedRun.new
    run.input_each_frame { |frame| frame == 5 ? [:a] : (frame == 9 ? [:b] : []) }
       .run(program_of do
         screen :tiled
         image :wall, "#" => :gray, "." => rgb(10, 3, 3) do
           "#.######\n" + ("########\n" * 6) + ".######.\n"
         end
         image :water, "~" => :blue, "=" => rgb(12, 12, 31) do
           "~~==~~~~\n" * 8
         end
         tiles :set, "#" => :wall, "~" => :water
         room = background :room, tiles: :set, map: {
           one: "##########\n#~~~~~~~~#\n#~~~##~~~#\n##########\n",
           two: "~~~~~~~~~~\n~########~\n~~~~~~~~~~\n~~~~~~~~~~\n"
         }
         x = var :x, 0
         game_loop do
           x.add! 3
           room.scroll_to x, x / 2
           pressed(:a).then { room.set_tile 2, 1, "#" }
           pressed(:b).then { room.show_map 1 }
         end
       end, frames: 14)

    assert_operator run[:x], :>, 0
  end

  # A 64×64 map is 8192 bytes of video RAM, two blanks' worth and more, handed to a background in
  # one pass. It arrives over several blanks with the screen on, and no frame is black: the checked
  # run holds each pass's picture to the interpreter's, and the frames between are read one by one.
  # The view is on the map's last quarter, the last piece copied, so a piece written after its
  # blank ended, and lost, shows as a picture that differs.
  def test_a_big_map_handed_to_a_background_shows_no_black_frame
    program = program_of do
      screen :tiled
      image(:wall, "#" => :gray) { "########\n" * 8 }
      image(:gem, "g" => :green) { "gggggggg\n" * 8 }
      tiles :set, "#" => :wall, "g" => :gem
      room = background :room, tiles: :set, map: { walls: "#{'#' * 64}\n" * 64, gems: "#{'g#' * 32}\n" * 64 }
      game_loop do
        room.scroll_to 260, 280
        pressed(:a).then { room.show_map 1 }
      end
    end
    press = ->(frame) { frame == 3 ? [:a] : [] }
    SNES::CheckedRun.new.input_each_frame(&press).run(program, frames: 8)
    run = SNES::HeadlessRun.new(watch_picture: true).input_each_frame(&press).run(program, frames: 8)

    assert_operator run.frames_took(4), :>, 1, "the map takes more than one blank"
    assert_empty run.black_frames
  end

  # Each changed cell is a word written on its own, and 200 of them take longer than a blank.
  def test_many_cells_changed_in_one_pass_show_no_black_frame
    program = program_of do
      screen :tiled
      image(:wall, "#" => :gray) { "########\n" * 8 }
      image(:gem, "g" => :green) { "gggggggg\n" * 8 }
      tiles :set, "#" => :wall, "g" => :gem
      room = background :room, tiles: :set, map: "#{'#' * 32}\n" * 32
      i = var :i, 0
      game_loop do
        pressed(:a).then do
          i.set! 0
          repeat(200) do
            room.set_tile i % 25, i / 25, "g"
            i.add! 1
          end
        end
      end
    end
    press = ->(frame) { frame == 3 ? [:a] : [] }
    SNES::CheckedRun.new.input_each_frame(&press).run(program, frames: 8)
    run = SNES::HeadlessRun.new(watch_picture: true).input_each_frame(&press).run(program, frames: 8)

    assert_empty run.black_frames
  end

  # A STATUS BAR shows from its top row to the bottom of the screen, over a field that scrolls under
  # it and is hidden there: the bar's see-through pixels, and its rows past its two, show the
  # backdrop. A sprite goes over it. The bar is moved each pass, to rows either side of 127 (the
  # most one step of the console's line table counts), to the top, past the bottom and above it,
  # and a cell of it changes.
  def test_a_status_bar_hides_the_field_under_it_wherever_it_is_put
    run = checked(frames: 14) do
      screen :tiled
      image(:dark, "#" => :blue) { "########\n" * 8 }
      image(:star, "#" => :yellow, "." => :blue) { "........\n...#....\n..###...\n...#....\n" + ("........\n" * 4) }
      image(:edge, "#" => :gray) { "########\n" * 8 }
      image(:pip, "#" => :green, "." => :transparent) { "..##....\n" * 8 }
      image(:ball, "#" => :white) { "####\n" * 4 }
      tiles :field_tiles, "." => :dark, "*" => :star
      tiles :bar_tiles, "[" => :edge, "o" => :pip
      field = background :field, tiles: :field_tiles, map: Array.new(32) { |row| (0...32).map { |col| (row + col) % 5 == 0 ? "*" : "." }.join }
      bar = status_bar :score, tiles: :bar_tiles, map: ["[oooo[", "[[[[[["], top: 200
      ball = sprite :ball, at: [20, 190]
      tops = table :tops, [200, 0, 127, 128, 150, 224, 300, -5, 60, 126, 223]
      t = var :t, 0
      game_loop do
        field.scroll_by 1, -1
        ball.move_to 20 + (t * 3), 190
        bar.move_to tops[t % 11]
        (t == 4).then { bar.set_tile 2, 0, "[" }
        t.add! 1
      end
    end

    assert_equal 14, run[:t]
  end

  # A bar that a scene puts up, and takes down when another scene takes over, is not made yet.
  def test_a_status_bar_that_a_scene_puts_up_is_refused_in_plain_words
    error = assert_raises(SNES::Lowering::NotMadeYet) do
      SNES.new.build(program_of do
        screen :tiled
        image(:edge, "#" => :gray) { "########\n" * 8 }
        tiles :bar_tiles, "[" => :edge
        state = var :state, 0
        scene(:play) { status_bar :score, tiles: :bar_tiles, map: ["[["], top: 200 }
        game_loop { case_var(:state) { when_val 0, :play } }
        state.set! 0
      end)
    end

    assert_match(/status bar that a scene puts up/, error.message)
  end

  private def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :snes }
  end

  private def checked(frames: nil, &game)
    SNES::CheckedRun.new.run(program_of(&game), frames: frames)
  end
end
