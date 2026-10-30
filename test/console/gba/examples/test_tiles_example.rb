# frozen_string_literal: true

require "test_helper"

require "stringio"
require VBlank.root.join("examples/tiles").to_s

# The points the tiles example's tests read, shared with its cartridge's own tests
# (test/lowering/gba/examples/test_tiles_example_cartridge.rb).
module TilesExamplePoints
  # Points chosen from the map (examples/tiles.rb), one per tile kind:
  #   (3,3)    — inside the top-left wall tile (cell 0,0)
  #   (40,24)  — inside the top-left water pool (cols 3-7, rows 2-4)
  #   (152,24) — inside the top-right grass patch (cols 18-20, rows 2-4)
  WALL  = [3, 3].freeze
  WATER = [40, 24].freeze
  GRASS = [152, 24].freeze
end

# The tiles example (examples/tiles.rb): a whole room drawn out of four 8x8 tiles
# stamped onto a grid by a character map. Proves the tiles/background surface
# renders the room — the right tile in the right cell — on every run that plays the
# Advance, and on the Advance's cartridge in the file named above.
class TestTilesExample < Minitest::Test
  include TilesExamplePoints

  def test_each_tile_kind_lands_where_the_map_puts_it
    i = game_player.run(Tiles.program)
    assert_equal Color.resolve(:gray),  i.screen.pixel(*WALL),  "the wall border renders gray"
    assert_equal Color.resolve(:blue),  i.screen.pixel(*WATER), "the water pool renders blue"
    assert_equal Color.resolve(:green), i.screen.pixel(*GRASS), "the grass patch renders green"
  end
end
