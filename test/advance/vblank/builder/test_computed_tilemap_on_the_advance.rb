# frozen_string_literal: true

require "test_helper"

# The test of test_computed_tilemap.rb that paints a background of a hundred shades onto a
# bitmap screen, so it plays on the Advance's runs alone. A Game Boy Color's painted screen
# holds four colours at once.
class TestComputedTilemapOnTheAdvance < Minitest::Test
  # A 4x4 solid tile of one colour: cell (c, r) covers x 4c..4c+3, y 4r..4r+3.
  private def solid_tile(builder, name, color)
    builder.image(name, "#" => color) { "####\n####\n####\n####" }
  end

  # A tileset of +count+ tiles keyed 0, 1, 2…, each its own shade.
  private def big_tileset(builder, count)
    count.times { |n| solid_tile(builder, :"tile_#{n}", VBlank::Graphics::Color.rgb(n % 32, 0, 0)) }
    keyed = (0...count).to_h { |n| [n, :"tile_#{n}"] }
    builder.tiles(:many, keyed)
  end

  def test_a_map_can_use_more_tiles_than_there_are_characters_to_type
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
    end
    big_tileset(b, 100)
    b.instance_eval do
      background :field, tiles: :many, map: (0...10).map { |r| (0...10).map { |c| (r * 10) + c } }
    end
    b.finalize_program
    i = game_player.run(b.program)
    assert_equal VBlank::Graphics::Color.rgb(0, 0, 0),  i.screen.pixel(0, 0),   "cell (0,0) is tile 0"
    assert_equal VBlank::Graphics::Color.rgb(99 % 32, 0, 0), i.screen.pixel(36, 36),
                 "cell (9,9) is tile 99 — a tile no character could have selected"
  end
end
