# frozen_string_literal: true

require "test_helper"
require "differential"

# A BACKGROUND THAT DRAWS WITH A DIFFERENT SET OF COLOURS while the game runs — shafts of
# light that shimmer, water that turns murky, a sky that goes from day to dusk. The scenery
# does not change: every pixel of every tile keeps its place in the list the tiles were drawn
# from, and only the colours those places show are swapped for another list's.
#
# It is the same verb a sprite already has, and underneath it is not the same thing at all. A
# sprite is POINTED at another set of sixteen colours — the display holds several sets and the
# sprite's own entry says which — where a background's every cell names its set, so the layer
# is recoloured by writing the new colours INTO the set its tiles read. Nothing about that
# reaches the program, which is the point of the verb reading the same.
class TestBackgroundDrawsWith < Minitest::Test
  include Differential

  OWN = %i[transparent red green].freeze
  SHIMMER = %i[transparent yellow white].freeze

  # An 8x8 tile, left half the first colour of the list and right half the second, so a
  # swapped colour shows at a known place.
  BAR = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  private def a_wall_of_bars(&game)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :bar, width: 8, height: 8, data: BAR, colors: OWN
      colors :shimmer, SHIMMER
      tiles :wall, "#" => :bar
      rays = background :rays, tiles: :wall, map: Array.new(20) { "#" * 30 }
      game_loop { instance_exec(rays, &game) }
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_background_told_to_draw_with_other_colors_shows_them
    i = Reference.new.run(a_wall_of_bars { |rays| rays.draw_with :shimmer }, frames: 3)

    assert_equal Color.resolve(:yellow), i.screen.pixel(1, 1), "the first place of the list"
    assert_equal Color.resolve(:white), i.screen.pixel(5, 1), "and the second"
  end

  def test_the_console_draws_the_other_colors_too
    v = assert_emulator_loads_rom(assemble_rom(a_wall_of_bars { |rays| rays.draw_with :shimmer }, name: "BGSWAP"),
                                  frames: 3)

    assert_equal Color.resolve(:yellow), v.pixel_gba(1, 1), "the first place of the list"
    assert_equal Color.resolve(:white), v.pixel_gba(5, 1), "and the second"
  end

  # Every pixel rather than the two sampled above.
  def test_the_two_backends_agree_about_a_recoloured_layer
    assert_backends_agree(a_wall_of_bars { |rays| rays.draw_with :shimmer }, frames: 3)
  end

  # --- ONE OF SEVERAL, PICKED BY A NUMBER THE GAME WORKS OUT ---
  #
  # This is the shape the effect is really for: several lists and a counter walking them, so
  # a layer shimmers, or a sky walks from dawn through dusk. The counter here steps every
  # frame and walks off the end, which is what says a number naming no list leaves the layer
  # in the colours it was drawn in rather than drawing something wrong.

  DAWN = %i[transparent orange yellow].freeze
  DUSK = %i[transparent magenta blue].freeze

  private def a_wall_that_walks_through_its_lists
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :bar, width: 8, height: 8, data: BAR, colors: OWN
      colors :dawn, DAWN
      colors :dusk, DUSK
      tiles :wall, "#" => :bar
      rays = background :rays, tiles: :wall, map: Array.new(20) { "#" * 30 }
      step = var :step, 0
      game_loop do
        rays.draw_with %i[dawn dusk], showing: step
        step.add! 1
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_number_the_game_works_out_picks_which_list
    prog = a_wall_that_walks_through_its_lists
    left = ->(frames) { Reference.new.run(prog, frames: frames).screen.pixel(1, 1) }

    # The display is told in the gap before a frame, from the number the pass before settled
    # on — the same frame behind every picture the framework draws for you.
    assert_equal Color.resolve(:red), left.call(1), "nothing has been said yet, so it is as drawn"
    assert_equal Color.resolve(:orange), left.call(2), "the counter said 0"
    assert_equal Color.resolve(:magenta), left.call(3), "...then 1"
    assert_equal Color.resolve(:red), left.call(4), "...then 2, which names no list: as drawn again"
  end

  def test_the_console_walks_the_lists_the_same_way
    assert_backends_agree(a_wall_that_walks_through_its_lists, frames: 4)
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
    builder.emit_pending_functions
    builder.program
  end

  def test_recolouring_one_layer_leaves_another_drawn_from_the_same_colours_alone
    v = assert_emulator_loads_rom(assemble_rom(two_walls_drawn_from_the_same_colours, name: "BGOWNPAL"), frames: 4)

    assert_equal Color.resolve(:yellow), v.pixel_gba(1, 1), "the layer that was told to shimmer"
    assert_equal Color.resolve(:red), v.pixel_gba(1, 120),
                 "the layer behind it changed colour too: the two are sharing one set of sixteen"
  end

  # Told to go back to its own colours, it does — the third form of the verb.
  def test_a_layer_can_be_put_back_in_its_own_colours
    i = Reference.new.run(a_wall_of_bars { |rays| rays.draw_with :own }, frames: 3)

    assert_equal Color.resolve(:red), i.screen.pixel(1, 1)
    assert_equal Color.resolve(:green), i.screen.pixel(5, 1)
  end

  # --- A RECOLOURED LAYER UNDER A TINT ---
  #
  # These two move the same table. Every pixel of a tiled screen is drawn by looking a
  # colour up in one shared table, which is out of reach of the display's own colour mixing
  # — so a tint walks the table itself, moving every colour the game declared toward the
  # tint colour (see PaletteTint). A layer drawn with another list writes sixteen entries of
  # that same table. Both writers have to land, and in the right order, or the shimmer is
  # painted back over by the colours the tiles were drawn in.
  private def a_wall_that_shimmers_while_the_screen_reddens
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :bar, width: 8, height: 8, data: BAR, colors: OWN
      colors :shimmer, SHIMMER
      tiles :wall, "#" => :bar
      rays = background :rays, tiles: :wall, map: Array.new(20) { "#" * 30 }
      hurt = var :hurt, 0
      game_loop do
        rays.draw_with :shimmer
        hurt.approach! 60, 20 # it moves every frame, so the table is rewritten every frame
        tint :red, hurt
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_tint_over_a_recoloured_layer_moves_the_colours_it_is_drawn_with
    assert_backends_agree(a_wall_that_shimmers_while_the_screen_reddens, frames: 5)
  end

  # --- the footguns this makes plain-language errors ---

  def test_giving_a_bitmap_background_other_colours_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        image :bar, width: 8, height: 8, data: BAR, colors: OWN
        colors :shimmer, SHIMMER
        tiles :wall, "#" => :bar
        background(:rays, tiles: :wall, map: ["#"]).draw_with :shimmer
      end
    end

    assert_match(/draw_with/, err.message)
    assert_match(/blit/, err.message, "it says what to do on that screen instead")
  end

  # A turning layer's cells hold a tile number and nothing else, so its tiles read every
  # colour in the game rather than a list of their own — there is no list to swap. Refused
  # whichever order the two are written in, since neither verb can know about the other.
  def test_giving_a_turning_background_other_colours_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :rotozoom
        image :bar, width: 8, height: 8, data: BAR, colors: OWN
        colors :shimmer, SHIMMER
        tiles :wall, "#" => :bar
        background(:rays, tiles: :wall, map: Array.new(32) { "#" * 32 }).scale(2.0).draw_with(:shimmer)
      end
    end

    assert_match(/turns or resizes/, err.message)
    assert_match(/draw with other colors/, err.message)
  end

  def test_turning_a_background_that_draws_with_other_colours_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :tiled
        image :bar, width: 8, height: 8, data: BAR, colors: OWN
        colors :shimmer, SHIMMER
        tiles :wall, "#" => :bar
        background(:rays, tiles: :wall, map: Array.new(32) { "#" * 32 }).draw_with(:shimmer).scale(2.0)
      end
    end

    assert_match(/draws background :rays with other colors/, err.message)
    assert_match(/turn or resize/, err.message)
  end
end
