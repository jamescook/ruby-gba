# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_background_draws_with"

# A RECOLOURED BACKGROUND ON THE ADVANCE'S CARTRIDGE, its pixels read in the emulator. What
# `draw_with` does to a background on every run is in
# test/all/vblank/dsl/test_background_draws_with.rb.
class TestBackgroundDrawsWithCartridge < Minitest::Test
  include BackgroundDrawsWithGames

  def test_the_console_draws_the_other_colors_too
    v = assert_emulator_loads_rom(assemble_rom(a_wall_of_bars { |rays| rays.draw_with :shimmer }, name: "BGSWAP"),
                                  frames: 3)

    assert_equal Color.resolve(:yellow), v.pixel_gba(1, 1), "the first place of the list"
    assert_equal Color.resolve(:white), v.pixel_gba(5, 1), "and the second"
  end

  # The colour behind everything is not one of the layer's
  # (BackgroundDrawsWithGames#a_wall_with_gaps_and_lists_that_start_with_a_colour).
  def test_a_list_that_starts_with_a_colour_leaves_the_backdrop_as_it_was
    wall = a_wall_with_gaps_and_lists_that_start_with_a_colour
    v = assert_emulator_loads_rom(assemble_rom(wall, name: "BGBACK"), frames: 4)

    assert_equal Color.resolve(:yellow), v.pixel_gba(1, 1), "the wall is drawn with the other list"
    assert_equal Color.resolve(:black), v.pixel_gba(9, 1), "and the gap beside it is still the backdrop"
  end

  # --- THE LAYER'S COLOURS ARE ITS OWN ---
  #
  # The console draws every pixel by looking a colour up in one shared table, and the
  # framework normally lets two pictures drawn from the same colours share one group of
  # sixteen entries — a saving nobody has to hear about. It stops being invisible the moment
  # a layer can be recoloured, because the swap writes INTO that group: anything else
  # reading it would change colour too, and nothing in the program would say why.
  #
  # So a layer that can be recoloured gets a group nobody else reads. This is the test that
  # says so, and it can only be asked of the console — the interpreter has no groups to
  # share, so it agrees whatever the build decided.
  private def two_walls_drawn_from_the_same_colours
    front = Array.new(20) { |r| (r < 10 ? "#" : " ") * 30 }
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :bar_front, width: 8, height: 8, data: BAR, colors: OWN
      image :bar_back, width: 8, height: 8, data: BAR, colors: OWN
      colors :shimmer, SHIMMER
      tiles :front_wall, "#" => :bar_front
      tiles :back_wall, "#" => :bar_back
      layers :far, :near
      layer(:far) { background :steady, tiles: :back_wall, map: Array.new(20) { "#" * 30 } }
      rays = layer(:near) { background :rays, tiles: :front_wall, map: front }
      game_loop { rays.draw_with :shimmer }
    end
    builder.finalize_program
    builder.program
  end

  def test_recolouring_one_layer_leaves_another_drawn_from_the_same_colours_alone
    v = assert_emulator_loads_rom(assemble_rom(two_walls_drawn_from_the_same_colours, name: "BGOWNPAL"), frames: 4)

    assert_equal Color.resolve(:yellow), v.pixel_gba(1, 1), "the layer that was told to shimmer"
    assert_equal Color.resolve(:red), v.pixel_gba(1, 120),
                 "the layer behind it changed colour too: the two are sharing one set of sixteen"
  end
end
