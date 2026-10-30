# frozen_string_literal: true

require "test_helper"

require "stringio"
require VBlank.root.join("examples/level").to_s
require VBlank.root.join("tools/make_example_assets").to_s # the art's colors, so expectations track the source

# The colours the Level example paints and the places to read them, kept once for this file
# and for the test of the level on the Advance's cartridge
# (test/lowering/gba/examples/test_level_example_cartridge.rb).
module LevelExampleSpots
  Assets = MakeExampleAssets

  BRICK = Assets::BRICK # a wall-tile body pixel (CSV tile number 1)
  FLOOR = Assets::FLOOR # a floor-tile pixel   (CSV tile number 2)
  HERO  = Assets::HERO  # the hero's green body

  # Points chosen on uniform regions: a brick pixel in the top wall (row 0 of the CSV),
  # a floor pixel in the open interior, the hero's solid body, and the hero's
  # transparent corner (over floor). The border-vs-interior split is exactly what
  # proves the CSV's 1s mapped to brick and 2s to floor.
  BRICK_AT = [100, 3].freeze
  FLOOR_AT = [100, 100].freeze
  BODY_AT  = [24, 24].freeze  # hero starts at [16,16]; +8,+8 is its body block
  CORNER_AT = [16, 16].freeze # the hero's transparent corner -> floor shows through
end

# The Level example (examples/level.rb): the CSV-tilemap import path. A tile sheet is
# imported as numbered tiles and the level is read from a .csv exported the way a map
# editor (Tiled) writes one — a grid of tile numbers — then rendered as a background
# with a hero over it. This proves the "map comes from an editor export" acceptance
# goal; the same level on the Advance's cartridge is in
# test/lowering/gba/examples/test_level_example_cartridge.rb.
#
# It uses the real ImageMagick adapter and does NOT skip when it's missing: importing
# is the whole point, so its absence is a real failure.
class TestLevelExample < Minitest::Test
  include VBlank::Console::Hardware
  include LevelExampleSpots

  def test_the_example_builds_clean
    rom = Level.build_rom(out: StringIO.new, err: StringIO.new)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # On the interpreter: the CSV's tile numbers render as the room (border brick, open
  # floor), with the imported transparent hero drawn over it.
  def test_the_csv_level_renders_on_the_interpreter
    s = game_player.run(Level.program, max_steps: 400).screen

    assert_equal BRICK, s.pixel(*BRICK_AT), "CSV tile 1 (brick) paints the wall border"
    assert_equal FLOOR, s.pixel(*FLOOR_AT), "CSV tile 2 (floor) paints the interior"
    assert_equal HERO,  s.pixel(*BODY_AT),  "the imported sprite draws over the CSV background"
    assert_equal FLOOR, s.pixel(*CORNER_AT), "the sprite's cut-out corner lets the floor show through"
  end
end
