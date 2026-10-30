# frozen_string_literal: true

require "test_helper"

# THE TESTS OF vblank/builder/test_scaled_and_scrolling_backgrounds.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file.
#
# A background that turns or resizes, BESIDE ordinary scrolling ones, on one screen.
#
# The console has three tile arrangements and the framework offered the two extremes:
# `screen :tiled` gives four scrolling layers and none of them can turn, `screen
# :rotozoom` gives one layer that turns and resizes and nothing else. The middle one —
# two scrolling layers plus one that turns — is the arrangement nearly every game that
# turns anything actually wants, because a turning layer is almost never the whole
# picture: a title where an object flies at the player over a backdrop, a map screen
# that spins inside a fixed frame, a road that banks under a sky and a status bar.
#
# Nothing in a program says which arrangement it wants. A background is one that turns
# because the program turns it, and the build picks the hardware that holds what was
# declared.
class TestScaledAndScrollingBackgroundsOnTheAdvance < Minitest::Test
  # A solid 8x8 tile of one colour, so a cell's colour is the whole assertion.
  private def solid_tile(builder, name, color)
    builder.image(name, "#" => color) { "########\n" * 8 }
  end

  # Rows of cells with one mark in them, the rest blank.
  private def marked_map(cols, rows, marks)
    grid = Array.new(rows) { Array.new(cols, " ") }
    marks.each { |(c, r), ch| grid[r][c] = ch }
    grid.map(&:join)
  end

  # THE ARRANGEMENT ITSELF: two ordinary scrolling layers and one that resizes, all on
  # one screen, all three showing. Built at the size it was drawn (1.0) so the picture
  # reads exactly as authored and each layer is judged by one pixel.
  private def three_layer_program(scale: 1.0)
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue, :blue)
    solid_tile(b, :i_red, :red)
    solid_tile(b, :i_green, :green)
    sky = marked_map(30, 20, {}).map { |row| row.tr(" ", "#") }
    rays = marked_map(30, 20, { [1, 1] => "$" })
    sword = marked_map(32, 32, { [2, 2] => "%" })
    b.instance_eval do
      tiles :t_sky,   "#" => :i_blue
      tiles :t_rays,  "$" => :i_red
      tiles :t_sword, "%" => :i_green
      background :sky,  tiles: :t_sky,  map: sky
      background :rays, tiles: :t_rays, map: rays
      background(:sword, tiles: :t_sword, map: sword).scale(scale)
      halt
    end
    b.finalize_program
    b.program
  end

  def test_two_scrolling_layers_and_one_that_resizes_all_draw
    s = game_player.run(three_layer_program).screen
    assert_equal Color.resolve(:blue),  s.pixel(100, 100), "the backmost scrolling layer fills the screen"
    assert_equal Color.resolve(:red),   s.pixel(12, 12),   "the middle scrolling layer draws over it"
    assert_equal Color.resolve(:green), s.pixel(20, 20),   "the resizing layer draws over both"
  end

  # The layer really is resized, not merely drawn: at twice the size a mark two cells
  # from the top-left is drawn further out from the middle of the screen, which is what
  # this layer pivots on.
  def test_the_resizing_layer_is_actually_resized
    plain = game_player.run(three_layer_program(scale: 1.0)).screen
    zoomed = game_player.run(three_layer_program(scale: 2.0)).screen
    assert_equal Color.resolve(:green), plain.pixel(20, 20), "at its drawn size the mark is where it was drawn"
    refute_equal Color.resolve(:green), zoomed.pixel(20, 20), "at twice the size it has moved off that pixel"
  end

  # A scrolling layer keeps everything screen :tiled gives it while a resizing layer
  # shares the screen — the scroll is the one worth asserting, because it is the hardware
  # the resizing layer does NOT have.
  def test_a_scrolling_layer_still_scrolls_beside_a_resizing_one
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue, :blue)
    solid_tile(b, :i_red, :red)
    rays = marked_map(30, 20, { [1, 1] => "$" })
    sword = marked_map(32, 32, {})
    b.instance_eval do
      tiles :t_rays,  "$" => :i_red
      tiles :t_sword, "#" => :i_blue
      moving = background :rays, tiles: :t_rays, map: rays
      background(:sword, tiles: :t_sword, map: sword).scale(1.0)
      game_loop do
        wait_vblank
        moving.scroll_by 8, 0 # one whole cell a frame, left
      end
    end
    b.finalize_program
    # The scroll is applied at the frame boundary, so the moved picture is the SECOND
    # frame's — the same one frame of lag a scroll has with no resizing layer present.
    s = game_player.run(b.program, frames: 2).screen
    assert_equal Color.resolve(:red), s.pixel(4, 12), "the mark moved one cell left as the layer scrolled"
    refute_equal Color.resolve(:red), s.pixel(12, 12), "...and is no longer where it was drawn"
  end

  # THE WHOLE POINT IS THAT THE PLAIN LAYERS LOSE NOTHING, and swapping a map and
  # changing one cell are the two that touch a layer's cells rather than its registers —
  # the ones a different hardware arrangement could plausibly have broken. A game with a
  # turning title over rooms it walks between needs both.
  def test_a_plain_layer_keeps_show_map_and_set_tile_beside_a_resizing_one
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_red, :red)
    solid_tile(b, :i_green, :green)
    solid_tile(b, :i_blue, :blue)
    hall = marked_map(30, 20, {}).map { |row| row.tr(" ", "R") }
    cave = marked_map(30, 20, {}).map { |row| row.tr(" ", "G") }
    square = marked_map(32, 32, {})
    b.instance_eval do
      tiles :t, "R" => :i_red, "G" => :i_green
      tiles :t_spin, "#" => :i_blue
      rooms = background :rooms, tiles: :t, map: { hall: hall, cave: cave }
      background(:spin, tiles: :t_spin, map: square).scale(1.0)
      game_loop do
        wait_vblank
        rooms.show_map :cave
        rooms.set_tile 0, 0, "R"
      end
    end
    b.finalize_program
    s = game_player.run(b.program, frames: 3).screen
    assert_equal Color.resolve(:green), s.pixel(44, 44), "show_map handed the plain layer the other room"
    assert_equal Color.resolve(:red),   s.pixel(4, 4),   "...and set_tile put one of its cells back"
  end

  # THE STACK DECIDES WHERE THE TURNING LAYER SITS, like anything else the console
  # redraws — it is not pinned in front just because of the hardware it uses. A layer
  # declared behind a solid one is covered by it.
  def test_the_stack_can_put_the_resizing_layer_behind_a_scrolling_one
    b = Builder.new
    b.instance_eval do
      screen :tiled
      layers :under, :over
    end
    solid_tile(b, :i_blue, :blue)
    solid_tile(b, :i_red, :red)
    full = marked_map(30, 20, {}).map { |row| row.tr(" ", "#") }
    square = marked_map(32, 32, {}).map { |row| row.tr(" ", "#") }
    b.instance_eval do
      tiles :t_spin, "#" => :i_blue
      tiles :t_flat, "#" => :i_red
      layer(:under) { background(:spin, tiles: :t_spin, map: square).scale(1.0) }
      layer(:over)  { background :flat, tiles: :t_flat, map: full }
      halt
    end
    b.finalize_program
    assert_equal Color.resolve(:red), game_player.run(b.program).screen.pixel(100, 100),
                 "the scrolling layer in front covers the resizing one behind it"
  end

  # A SEE-THROUGH LAYER IS THE OTHER THING screen :tiled gives that this must not cost,
  # because it is the half of a title screen that the turning piece flies over: rays or
  # mist blended over a backdrop while something zooms in front of them.
  def test_a_see_through_layer_still_shows_through_beside_a_resizing_one
    b = Builder.new
    b.instance_eval do
      screen :tiled
      layers :behind, :water, :front
    end
    solid_tile(b, :i_blue, :blue)
    solid_tile(b, :i_red, :red)
    full = marked_map(30, 20, {}).map { |row| row.tr(" ", "#") }
    square = marked_map(32, 32, {})
    b.instance_eval do
      tiles :t_blue, "#" => :i_blue
      tiles :t_red,  "#" => :i_red
      layer(:behind) { background :deep, tiles: :t_blue, map: full }
      layer(:water, transparency: 50) { background :top, tiles: :t_red, map: full }
      layer(:front) { background(:spin, tiles: :t_blue, map: square).scale(1.0) }
      halt
    end
    b.finalize_program
    got = game_player.run(b.program).screen.pixel(100, 100)
    refute_equal Color.resolve(:red),  got, "the see-through layer is not drawn solid"
    refute_equal Color.resolve(:blue), got, "...nor is the layer behind it left uncovered"
    assert_equal see_through_red_over_blue, got, "half of each, exactly as with no turning layer present"
  end

  # What half red over blue comes out as — measured from the same program with the
  # turning layer left out, so this pins the blend to what screen :tiled already did
  # rather than to arithmetic restated here.
  private def see_through_red_over_blue
    b = Builder.new
    b.instance_eval do
      screen :tiled
      layers :behind, :water
    end
    solid_tile(b, :i_blue, :blue)
    solid_tile(b, :i_red, :red)
    full = marked_map(30, 20, {}).map { |row| row.tr(" ", "#") }
    b.instance_eval do
      tiles :t_blue, "#" => :i_blue
      tiles :t_red,  "#" => :i_red
      layer(:behind) { background :deep, tiles: :t_blue, map: full }
      layer(:water, transparency: 50) { background :top, tiles: :t_red, map: full }
      halt
    end
    b.finalize_program
    game_player.run(b.program).screen.pixel(100, 100)
  end

  # --- Hardware: the console shows the same three layers ---

  # The low three bits of the display register say which arrangement the console is in.
  DISPLAY_MODE = 0x7

  # The same three layers with nothing resized — the control for the assertion above.
  private def scrolling_only_program
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue, :blue)
    full = marked_map(30, 20, {}).map { |row| row.tr(" ", "#") }
    b.instance_eval do
      tiles :t, "#" => :i_blue
      background :sky,  tiles: :t, map: full
      background :rays, tiles: :t, map: full
      halt
    end
    b.finalize_program
    b.program
  end
end
