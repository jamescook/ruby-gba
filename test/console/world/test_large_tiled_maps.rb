# frozen_string_literal: true

require "test_helper"
require "differential"

# A BACKGROUND BIGGER THAN ONE SCREENFUL OF GRID.
#
# A tiled background scrolls over a grid of fixed size, and it used to be one size: 32x32 tiles,
# 256x256 pixels. That is already larger than the screen and it wraps, so a small game never
# notices — but a level is not 256 pixels wide, and a bigger map was a friendly build error
# rather than a bigger map.
#
# The console has four sizes and the framework now picks the smallest that holds what was drawn.
# Nothing in the program says which: an author writes the map they want and either it fits or
# they are told plainly that it does not.
#
# WHAT MAKES THIS WORTH ITS OWN TESTS is that a map past one block is not laid out the way it
# reads. The console reads a wide map as two 32x32 SQUARES side by side, and a 64x64 one as four
# — top-left, top-right, bottom-left, bottom-right — so a cell's place in memory depends on
# which quarter of the map it is in. Get that wrong and the picture is not scrambled everywhere;
# it is right in the top-left quarter and wrong in the other three, which is exactly the bug a
# handful of spot checks miss.
class TestLargeTiledMaps < Minitest::Test
  include Differential

  SOLID8 = (["########"] * 8).join("\n")

  # A map of the given size, with a different colour in each quarter, so a cell landing in the
  # wrong block shows up as the wrong colour rather than as nothing.
  QUARTERS = %i[red green blue yellow].freeze

  def quartered_program(cols, rows, scroll: [0, 0])
    dx, dy = scroll
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      QUARTERS.each_with_index { |color, i| image(:"q#{i}", "#" => color) { SOLID8 } }
      tiles :set, "0" => :q0, "1" => :q1, "2" => :q2, "3" => :q3
      map = Array.new(rows) do |r|
        Array.new(cols) { |c| ((r >= 32 ? 2 : 0) + (c >= 32 ? 1 : 0)).to_s }.join
      end
      bg = background :field, tiles: :set, map: map
      game_loop do
        wait_vblank
        bg.scroll_to dx, dy
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  # --- the sizes build and draw ---

  def test_a_wide_map_shows_its_left_half_unscrolled
    screen = Reference.new.run(quartered_program(64, 32)).screen
    assert_equal Color.resolve(:red), screen.pixel(4, 4), "the top-left quarter is on screen"
  end

  # Scrolled past the first 32 cells, the right half is what shows — which is the half that
  # lives in the second block.
  def test_a_wide_map_shows_its_right_half_when_scrolled_there
    screen = Reference.new.run(quartered_program(64, 32, scroll: [256, 0])).screen
    assert_equal Color.resolve(:green), screen.pixel(4, 4), "the second block's tiles"
  end

  def test_a_tall_map_shows_its_bottom_half_when_scrolled_there
    screen = Reference.new.run(quartered_program(32, 64, scroll: [0, 256])).screen
    assert_equal Color.resolve(:blue), screen.pixel(4, 4)
  end

  def test_the_biggest_map_shows_its_far_corner
    screen = Reference.new.run(quartered_program(64, 64, scroll: [256, 256])).screen
    assert_equal Color.resolve(:yellow), screen.pixel(4, 4), "the fourth block's tiles"
  end

  # --- the console agrees, which is where the block layout is really under test ---

  def test_both_backends_agree_on_a_wide_map
    assert_backends_agree(quartered_program(64, 32, scroll: [200, 0]), frames: 6)
  end

  def test_both_backends_agree_on_the_biggest_map
    assert_backends_agree(quartered_program(64, 64, scroll: [200, 200]), frames: 6)
  end

  # A map that fills no more than the old size must still land in one block and draw the same,
  # so nothing that worked before moved.
  def test_a_small_map_still_uses_one_block
    backend = GBA.new
    backend.lower(quartered_program(32, 32))
    bg = backend.backgrounds.fetch(:field)

    assert_equal GBA::MAP_ENTRIES_A_BLOCK, bg.map_units, "one screen block, as before"
    assert_equal 0, bg.size, "and the smallest of the console's grid sizes"
  end

  def test_the_biggest_map_takes_four_blocks
    backend = GBA.new
    backend.lower(quartered_program(64, 64))
    bg = backend.backgrounds.fetch(:field)

    assert_equal 4 * GBA::MAP_ENTRIES_A_BLOCK, bg.map_units
  end

  # The four maps must not land on each other, however big each one is.
  def test_four_big_maps_get_runs_that_do_not_overlap
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:t, "#" => :red) { SOLID8 }
      tiles :set, "#" => :t
      map = Array.new(64) { "#" * 64 }
      4.times { |i| background :"layer#{i}", tiles: :set, map: map }
      game_loop {}
    end
    builder.emit_pending_functions

    backend = GBA.new
    backend.lower(builder.program)
    spans = backend.backgrounds.values.map { |bg| bg.screen_block...(bg.screen_block + 4) }
    spans.combination(2).each do |a, b|
      assert (a.to_a & b.to_a).empty?, "two maps share screen blocks: #{a} and #{b}"
    end
  end

  # --- what still does not fit ---

  def test_a_map_past_the_biggest_size_is_a_friendly_error
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:t, "#" => :red) { SOLID8 }
      tiles :set, "#" => :t
      background :huge, tiles: :set, map: Array.new(65) { "#" * 65 }
      game_loop {}
    end
    builder.emit_pending_functions

    error = assert_raises(GBA::LoweringError) { GBA.new.lower(builder.program) }
    assert_match(/:huge/, error.message)
    assert_match(/65x65/, error.message, "it says how big the map is")
    assert_match(/64x64/, error.message, "and how big one can be")
  end
end
