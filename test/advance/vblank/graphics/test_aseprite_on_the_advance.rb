# frozen_string_literal: true

require "test_helper"

# The tests of test_aseprite.rb whose games paint more colours into one 8×8 square of the screen
# than a Game Boy Color's square holds — a bitmap screen with a red, green, blue and white sprite
# over black — so they play on the Advance's runs alone.
class TestAsepriteOnTheAdvance < Minitest::Test
  # The JSON export's picture is read by the image tool, a child process, which Ruby cannot
  # reliably start from inside a Ractor — with these three spawning at once, one waits for
  # ever — so on the main Ractor, not in the pool. See test_helper.
  runs_on_the_main_ractor!

  include VBlank::Console::Hardware

  # The committed fixtures. A JSON+PNG export and a native .aseprite binary, both a 4-frame
  # sheet of red, green, blue, white. The JSON one is tagged walk = 0..1 / blink = 2..3;
  # the binary one is tagged walk = 0..1 / idle = 2..3.
  FIXTURE = VBlank.root.join("test/fixtures/aseprite/hero.json").to_s
  BINARY = VBlank.root.join("test/fixtures/aseprite/hero_rgba.aseprite").to_s

  private def game(mode:, run:, play: nil, file: FIXTURE)
    builder = Builder.new
    builder.instance_eval do
      screen mode
      if mode == :tiled
        image(:field, "#" => :black) { SOLID_TILE }
        tiles :ground, "#" => :field
        background :bg, tiles: :ground, map: Array.new(20, "#" * 30)
      else
        clear_screen :black
      end
      hero = sprite :hero, at: [40, 40], from_aseprite: file
      hero.play(play) if play # switch clip at setup; it holds while the loop animates it
      f = var :f, 0
      game_loop do
        wait_vblank
        f.add! 1
        (f >= run).then { halt }
      end
    end
    builder.finalize_program
    builder.program
  end

  private def spot(program) = game_player.run(program).screen.pixel(44, 44)
  private def c(r, g, b) = Color.rgb8(r, g, b)

  def test_the_default_animation_is_the_first_tag_and_it_loops
    assert_equal c(255, 0, 0), spot(game(mode: :bitmap, run: 3)), "walk starts on its first frame (red)"
    assert_equal c(0, 255, 0), spot(game(mode: :bitmap, run: 9)), "a few frames on, walk is on its second frame (green)"
    assert_equal c(255, 0, 0), spot(game(mode: :bitmap, run: 15)), "walk loops back to its first frame"
  end

  def test_playing_a_named_animation_switches_the_frames
    assert_equal c(0, 0, 255),     spot(game(mode: :bitmap, run: 3, play: :blink)), "blink's first frame (blue)"
    assert_equal c(255, 255, 255), spot(game(mode: :bitmap, run: 9, play: :blink)), "blink's second frame (white)"
  end

  def test_a_native_aseprite_file_imports_and_plays
    assert_equal c(255, 0, 0), spot(game(mode: :bitmap, run: 3, file: BINARY)), "native: walk's first frame (red)"
    assert_equal c(0, 255, 0), spot(game(mode: :bitmap, run: 9, file: BINARY)), "native: walk animates (green)"
    assert_equal c(0, 0, 255), spot(game(mode: :bitmap, run: 3, file: BINARY, play: :idle)), "native: play(:idle) (blue)"
  end
end
