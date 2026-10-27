# frozen_string_literal: true

require "test_helper"
require "differential"
require "status_bar_games"

# A STATUS BAR is a strip of tiles fixed to the screen, from a row the game says down to the
# bottom, over a field that scrolls and changes under it: the score along the bottom of a
# pinball table, the lives and keys along the bottom of a dungeon. It does not scroll with the
# field, it has its own tiles and colours, and the game can slide it down out of view and back
# (test/vblank/dsl/test_status_bar.rb).
#
# Every test lays the screen out from the console's own size, so it plays on the Advance and on
# the Color alike.
class TestStatusBar < Minitest::Test
  include Differential
  include StatusBarGames

  def test_the_bar_covers_the_bottom_rows_and_stays_while_the_field_scrolls_under_it
    prog = bar_game
    bar_row = screen_height - (BAR_HEIGHT / 2)

    [6, 9].each do |frames|
      assert_equal GREEN, picture(prog, frames).pixel(8, bar_row), "the bar after #{frames} passes"
    end
    above = (2..9).map { |frames| picture(prog, frames).pixel(8, 28) }
    assert_includes above, BLUE, "the field above the bar scrolls past its blue rows"
    assert_includes above, RED
    assert_backends_agree(prog, frames: [3, 9], name: "BAR")
  end

  # Past the last row of the bar's map, down to the bottom of the screen, is still the bar: the
  # field is not drawn there, and the backdrop shows.
  def test_rows_past_the_bars_map_show_the_backdrop_not_the_field
    prog = bar_game(from_bottom: 40)
    shown = picture(prog, 6)

    assert_equal GREEN, shown.pixel(8, screen_height - 36), "the bar's own rows"
    assert_equal BLACK, shown.pixel(8, screen_height - 8), "past its map"
    assert_backends_agree(prog, frames: 6, name: "BARPAST")
  end

  # A sprite is drawn over the bar, and the bar's see-through pixels show the backdrop rather
  # than the field under them.
  def test_a_sprite_shows_over_the_bar_and_its_see_through_pixels_show_the_backdrop
    prog = program do
      screen :tiled
      image(:red_art, "#" => :red) { SOLID_TILE }
      image(:edge_art, "#" => :green, "." => :transparent) { (["####...."] * 8).join("\n") }
      image(:ball, "#" => :white) { (["########"] * 8).join("\n") }
      tiles :field_tiles, "#" => :red_art
      tiles :bar_tiles, "#" => :edge_art
      background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
      status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: screen_height - 16
      sprite :ball, at: [40, screen_height - 12]
      game_loop {}
    end
    shown = picture(prog, 4)
    row = screen_height - 4

    assert_equal GREEN, shown.pixel(2, row)
    assert_equal BLACK, shown.pixel(6, row), "a see-through pixel of the bar"
    assert_equal Color.resolve(:white), shown.pixel(44, row - 4), "the sprite"
    assert_equal RED, shown.pixel(6, row - 20), "the field above the bar"
    assert_backends_agree(prog, frames: 4, name: "BARSPR")
  end

  # A bar takes no layer in a game that names its layers: it is in front of the backgrounds and
  # behind the sprites whatever the stack says.
  def test_a_bar_in_a_game_with_layers_is_in_front_of_the_backgrounds_and_behind_the_sprites
    prog = program do
      screen :tiled
      layers :world, :front
      image(:red_art, "#" => :red) { SOLID_TILE }
      image(:green_art, "#" => :green) { SOLID_TILE }
      image(:ball, "#" => :white) { (["########"] * 8).join("\n") }
      tiles :field_tiles, "#" => :red_art
      tiles :bar_tiles, "#" => :green_art
      layer(:front) { sprite :ball, at: [40, screen_height - 12] }
      layer(:world) { background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 } }
      status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: screen_height - 16
      game_loop {}
    end
    shown = picture(prog, 4)

    assert_equal GREEN, shown.pixel(8, screen_height - 4)
    assert_equal Color.resolve(:white), shown.pixel(44, screen_height - 8)
    assert_backends_agree(prog, frames: 4, name: "BARLAYER")
  end

  # The bars the console cannot keep where they are put are refused where they are written.
  def test_a_bar_the_console_cannot_keep_is_a_friendly_error
    {
      "needs a `screen :tiled`" => -> { screen :bitmap },
      "takes no layer" => -> { layers(:ui) && layer(:ui) { status_bar :score, tiles: :bar_tiles, map: ["#"], top: 0 } },
      "holds 32 by 32 cells" => -> { status_bar :score, tiles: :bar_tiles, map: ["#" * 33], top: 0 },
      "must be a whole number" => -> { status_bar :score, tiles: :bar_tiles, map: ["#"], top: var(:row, 3) }
    }.each do |phrase, misuse|
      error = assert_raises(ArgumentError, phrase) do
        program do
          screen :tiled
          image(:green_art, "#" => :green) { SOLID_TILE }
          tiles :bar_tiles, "#" => :green_art
          instance_exec(&misuse)
          status_bar :score, tiles: :bar_tiles, map: ["#"], top: 0
        end
      end
      assert_includes error.message, phrase
    end
  end

  # A game that runs +bar_scene+ from its first pass, a scene with nothing of its own from pass
  # 5, and +bar_scene+ again from pass 8, over a red field every screen shows.
  private def scene_leaves_and_comes_back(&bar_scene)
    program do
      screen :tiled
      image(:red_art, "#" => :red) { SOLID_TILE }
      image(:green_art, "#" => :green) { SOLID_TILE }
      image(:blue_art, "#" => :blue) { SOLID_TILE }
      tiles :field_tiles, "#" => :red_art
      tiles :bar_tiles, "#" => :green_art, "o" => :blue_art
      background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
      state = var :state, 0
      tick = var :tick, 0
      scene(:play) { instance_exec(tick, &bar_scene) }
      scene(:pause) {}
      game_loop do
        tick.add! 1
        (tick == 5).then { state.set! 1 }
        (tick == 8).then { state.set! 0 }
        case_var(:state) do
          when_val 0, :play
          when_val 1, :pause
        end
      end
    end
  end

  # A bar declared in one scene is up in that scene alone: the scene after it shows its field to
  # the bottom of the screen.
  def test_a_bar_belongs_to_the_scene_that_declares_it
    prog = scene_leaves_and_comes_back do
      status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: screen_height - 16
    end
    bottom = screen_height - 4

    assert_equal GREEN, picture(prog, 4).pixel(8, bottom)
    assert_equal RED, picture(prog, 6).pixel(8, bottom)
    assert_backends_agree(prog, frames: [4, 6], name: "BARSCN")
  end

  # A scene whose bar was moved and had a cell changed comes back with its bar as declared, at the
  # row it was declared with, until the game places it again — as a background comes back to its
  # corner and its first map.
  def test_a_scene_that_comes_back_puts_its_bar_up_as_declared
    prog = scene_leaves_and_comes_back do |tick|
      bar = status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: screen_height - 16
      (tick == 2).then { bar.move_to 40 }
      (tick == 3).then { bar.set_tile 1, 0, "o" }
    end

    assert_equal GREEN, picture(prog, 4).pixel(20, 44), "moved up"
    assert_equal BLUE, picture(prog, 4).pixel(12, 44), "and a cell of it changed"
    assert_backends_agree(prog, frames: [4, 8, 9, 10, 12], name: "BARBACK")
  end
end
