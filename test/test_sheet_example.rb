# frozen_string_literal: true

require "test_helper"

require "stringio"
require_relative "../examples/sheet"
require_relative "../tools/make_example_assets" # the art's colors, so expectations track the source

# The Sheet example (examples/sheet.rb): the whole asset-import path against real
# PNGs. A tile sheet is imported and rendered as a background; a transparent sprite
# sheet is imported and its frames animate a hero over that background. This proves
# both asset-pipeline acceptance goals — import a tileset + render it, import a
# sprite sheet + animate it — on the interpreter oracle AND on real hardware.
#
# It uses the real ImageMagick adapter and does NOT skip when it's missing:
# importing is the whole point, so its absence is a real failure.
class TestSheetExample < Minitest::Test
  include RubyGBA::Constants

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

  def test_the_example_builds_clean
    rom = Sheet.build_rom(out: StringIO.new, err: StringIO.new)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # On the interpreter: the imported tiles render as the room, and the imported,
  # transparent hero draws its body while letting the floor show through its cut-out
  # corner.
  def test_imported_tiles_and_sprite_render_on_the_interpreter
    s = Reference.new.run(Sheet.program, max_steps: 400).screen

    assert_equal BRICK, s.pixel(*BRICK_AT), "the imported brick tile paints the wall"
    assert_equal FLOOR, s.pixel(*FLOOR_AT), "the imported floor tile paints the interior"
    assert_equal HERO,  s.pixel(*BODY_AT),  "the imported sprite frame draws the hero's body"
    assert_equal FLOOR, s.pixel(*CORNER_AT), "the sprite's cut-out corner lets the floor show through"
  end

  # The same, on real hardware.
  def test_imported_tiles_and_sprite_render_on_the_console
    v = assert_gemba_loads_rom(Sheet.build_rom(out: StringIO.new, err: StringIO.new), frames: 12)

    assert v.pixel_is?(*BRICK_AT, BRICK), "brick, got 0x#{format('%04X', v.pixel_gba(*BRICK_AT))}"
    assert v.pixel_is?(*FLOOR_AT, FLOOR), "floor, got 0x#{format('%04X', v.pixel_gba(*FLOOR_AT))}"
    assert v.pixel_is?(*BODY_AT, HERO),   "hero body, got 0x#{format('%04X', v.pixel_gba(*BODY_AT))}"
    assert v.pixel_is?(*CORNER_AT, FLOOR),
           "floor through the hero's cut-out, got 0x#{format('%04X', v.pixel_gba(*CORNER_AT))}"
  end
end
