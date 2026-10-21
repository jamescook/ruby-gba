# frozen_string_literal: true

require "test_helper"

# THE TESTS OF ruby_gba/builder/test_scaled_and_scrolling_backgrounds.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
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
