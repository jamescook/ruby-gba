# frozen_string_literal: true

require "test_helper"

require VBlank.root.join("examples/sheet").to_s
require VBlank.root.join("tools/make_example_assets").to_s # the art's colors, so expectations track the source

# The art's colours and where to look for them, shared with the cartridge's tests
# (test/lowering/gba/examples/test_sheet_example_cartridge.rb).
module SheetExampleArt
  Assets = MakeExampleAssets

  BRICK = Assets::BRICK # a wall-tile body pixel
  FLOOR = Assets::FLOOR # a floor-tile pixel
  HERO  = Assets::HERO  # the hero's green body

  # Coordinates chosen on uniform regions of the art (see make_example_assets.rb):
  # a brick pixel in the top wall, a floor pixel in the open interior, the hero's
  # solid body, and the hero's transparent top-left corner (over floor).
  BRICK_AT = [100, 3].freeze
  FLOOR_AT = [100, 100].freeze
  BODY_AT  = [24, 24].freeze # hero starts at [16,16]; +8,+8 is its body block
  CORNER_AT = [16, 16].freeze # the hero's transparent corner -> floor shows through
end

# The Sheet example (examples/sheet.rb): the whole asset-import path against real
# PNGs. A tile sheet is imported and rendered as a background; a transparent sprite
# sheet is imported and its frames animate a hero over that background. This proves
# both asset-pipeline acceptance goals — import a tileset + render it, import a
# sprite sheet + animate it — on the run's own player here, and on real hardware in
# test/lowering/gba/examples/test_sheet_example_cartridge.rb.
#
# It uses the real ImageMagick adapter and does NOT skip when it's missing:
# importing is the whole point, so its absence is a real failure.
class TestSheetExample < Minitest::Test
  include VBlank::Console::Hardware
  include SheetExampleArt

  # On the interpreter: the imported tiles render as the room, and the imported,
  # transparent hero draws its body while letting the floor show through its cut-out
  # corner.
  def test_imported_tiles_and_sprite_render_on_the_interpreter
    s = game_player.run(Sheet.program, max_steps: 400).screen

    assert_equal BRICK, s.pixel(*BRICK_AT), "the imported brick tile paints the wall"
    assert_equal FLOOR, s.pixel(*FLOOR_AT), "the imported floor tile paints the interior"
    assert_equal HERO,  s.pixel(*BODY_AT),  "the imported sprite frame draws the hero's body"
    assert_equal FLOOR, s.pixel(*CORNER_AT), "the sprite's cut-out corner lets the floor show through"
  end
end
