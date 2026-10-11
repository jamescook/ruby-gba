# frozen_string_literal: true

require "test_helper"
require "native_comparison"

# A game's picture, drawn by the C runtime, shows the same pixel in every place the interpreter's
# does, at every frame boundary. Each test is a small game built through the DSL; the answer is
# the interpreter's picture (see NativeComparison).
class TestNativePicture < Minitest::Test
  # Starts child processes (zig, and the program it builds), which Ruby cannot do from inside a
  # Ractor — the spawn waits for ever — so on the main Ractor, not in the pool. See test_helper.
  runs_on_the_main_ractor!

  include NativeComparison

  def test_rectangles_pixels_and_a_clear_on_a_bitmap_screen
    program = program_of do
      screen :bitmap
      x = var :x, 230
      game_loop do
        clear_screen :blue
        fill_rect 10, 10, 20, 8, :red
        draw_rect_at x, 40, 30, 12, :yellow # runs off the right edge, and is clipped there
        pixel 5, 100, :white
        x.sub! 7
      end
    end

    last = assert_native_matches_reference(program, frames: 4)

    assert(last.picture.uniq.length > 2, "the picture should hold more than a clear")
  end

  def test_text_and_a_live_number
    program = program_of do
      screen :bitmap
      score = var :score, 0
      game_loop do
        clear_screen :black
        draw_text "PONG", :center, 40, :white
        draw_text "HI", 8, 8, [:gray, :white], showing: score > 2
        draw_number score, 100, 100, :green, digits: 2
        score.add! 1
      end
    end

    assert_native_matches_reference program, frames: 5
  end

  def test_a_flash_and_a_fade_mix_into_the_whole_picture
    program = program_of do
      screen :bitmap
      n = var :n, 0
      game_loop do
        clear_screen :cyan
        fill_rect 0, 0, 120, 160, :white
        (n == 1).then { flash_screen :red, frames: 6 }
        (n == 8).then { fade_out frames: 4 }
        n.add! 1
      end
    end

    assert_native_matches_reference program, frames: 14
  end

  # A menu on a bitmap screen is painted into the picture: rows, the cursor, the picked row lit.
  def test_a_menu_on_a_bitmap_screen_follows_the_cursor
    program = program_of do
      screen :bitmap
      chosen = var :chosen, 0
      game_loop do
        clear_screen :black
        menu :main, at: [60, 40], color: :gray, picked: :white do |m|
          m.item("PLAY") { chosen.set! 1 }
          m.item("QUIT") { chosen.set! 2 }
        end
      end
    end

    last = assert_native_matches_reference(program, frames: 8, buttons: { 3 => %i[down], 6 => %i[a] })

    assert_equal 2, last.variables[:chosen]
  end

  # A scene's own scenery is up only while that scene is: until the scene takes the screen
  # over, its background is not drawn, and once it has, it is.
  def test_a_scenes_scenery_shows_only_once_the_scene_takes_over
    program = program_of do
      screen :tiled
      state = var :state, 0
      ticks = var :ticks, 0
      image :brick, "#" => :red do "########\n" * 8 end
      tiles :wall, "#" => :brick
      scene(:waiting) do
        ticks.add! 1
        (ticks >= 3).then { state.set! 1 }
      end
      scene(:walled) { background :wall, tiles: :wall, map: ["#" * 30] * 20 }
      game_loop do
        case_var :state do
          when_val 0, :waiting
          when_val 1, :walled
        end
      end
    end

    assert_native_matches_reference program, frames: 6
  end

  def test_the_screen_is_white_until_the_first_frame
    program = program_of do
      screen :bitmap
      clear_screen :red
      game_loop { pixel 1, 1, :blue }
    end

    assert_native_matches_reference program, frames: 2
  end
end
