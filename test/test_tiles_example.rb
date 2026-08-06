# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"
require_relative "test_helper"
require_relative "../examples/tiles"

# The tiles example (examples/tiles.rb): a whole room drawn out of four 8x8 tiles
# stamped onto a grid by a character map. Proves the tiles/background surface
# renders the room — the right tile in the right cell — on the interpreter oracle
# and on real hardware.
class TestTilesExample < Minitest::Test
  include GembaSupport

  Reference = RubyGBA::IR::Backends::Reference
  Color = RubyGBA::Color

  # Points chosen from the map (examples/tiles.rb), one per tile kind:
  #   (3,3)    — inside the top-left wall tile (cell 0,0)
  #   (40,24)  — inside the top-left water pool (cols 3-7, rows 2-4)
  #   (152,24) — inside the top-right grass patch (cols 18-20, rows 2-4)
  WALL  = [3, 3].freeze
  WATER = [40, 24].freeze
  GRASS = [152, 24].freeze

  def test_each_tile_kind_lands_where_the_map_puts_it
    i = Reference.new.run(Tiles.program)
    assert_equal Color.resolve(:gray),  i.screen.pixel(*WALL),  "the wall border renders gray"
    assert_equal Color.resolve(:blue),  i.screen.pixel(*WATER), "the water pool renders blue"
    assert_equal Color.resolve(:green), i.screen.pixel(*GRASS), "the grass patch renders green"
  end

  # Tile mode draws the whole layer from data uploaded once at boot, so a couple of
  # frames is plenty — there's no per-tile stamping to wait on.
  def test_the_room_renders_on_the_console
    v = assert_gemba_loads_rom(Tiles.build_rom(err: StringIO.new), frames: 3)
    assert v.pixel_is?(*WALL, :gray), "wall renders on hardware, got 0x#{format('%04X', v.pixel_gba(*WALL))}"
    assert v.blue?(*WATER),  "water renders on hardware, got 0x#{format('%04X', v.pixel_gba(*WATER))}"
    assert v.green?(*GRASS), "grass renders on hardware, got 0x#{format('%04X', v.pixel_gba(*GRASS))}"
  end
end
