# frozen_string_literal: true

require "test_helper"

require "tempfile"
require VBlank.root.join("tools/make_example_assets").to_s # colors of the imported tile sheet

# The test of test_csv_tilemap.rb that paints the example tile sheet onto a bitmap screen, so it
# plays on the Advance's runs alone. The sheet has more colours than the four a Game Boy Color's
# painted screen holds at once.
class TestCsvTilemapOnTheAdvance < Minitest::Test
  Assets = MakeExampleAssets

  SHEET = VBlank.root.join("examples/assets/tiles.png").to_s # brick = tile 1, floor = tile 2

  # Write +text+ to a real .csv file for the duration of the block, then clean it up.
  private def with_csv(text)
    Tempfile.create(["tilemap", ".csv"]) do |f|
      f.write(text)
      f.flush
      yield f.path
    end
  end

  def test_a_whole_sheet_tileset_numbers_its_cells_for_a_csv_map
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      tiles :world, from: SHEET, tile: 8 # no characters: cell 0 -> tile 1, cell 1 -> tile 2
    end
    with_csv("1,2\n") { |path| b.background(:room, tiles: :world, from: path) }
    b.finalize_program
    s = game_player.run(b.program).screen
    assert_equal Assets::BRICK, s.pixel(0, 3), "CSV tile 1 is the sheet's first cell (brick)"
    assert_equal Assets::FLOOR, s.pixel(8, 3), "CSV tile 2 is the sheet's second cell (floor)"
  end
end
