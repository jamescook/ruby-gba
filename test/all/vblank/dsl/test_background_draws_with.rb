# frozen_string_literal: true

require "test_helper"
require "differential"

# The games these tests play, shared with the Advance cartridge's own tests of the same layers
# (test/lowering/gba/vblank/dsl/test_background_draws_with_cartridge.rb).
module BackgroundDrawsWithGames
  include SharedConstants

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
    builder.finalize_program
    builder.program
  end

  # THE COLOUR BEHIND EVERYTHING IS NOT ONE OF THE LAYER'S. The very first entry of the
  # scenery's table is the backdrop, shown wherever no layer draws. A list's first place
  # means see-through and is never drawn, but the colour written there is still a colour:
  # were the layer's set of sixteen the first one in the table, writing a list into it
  # would write that colour onto the backdrop. So a layer never gets the first set.
  #
  # A wall with gaps, drawn from a list written with magenta first and told to draw with
  # one written with cyan first. The gaps show the backdrop.
  private def a_wall_with_gaps_and_lists_that_start_with_a_colour
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :bar, width: 8, height: 8, data: BAR, colors: %i[magenta red green]
      colors :shimmer, %i[cyan yellow white]
      tiles :wall, "#" => :bar
      rays = background :rays, tiles: :wall, map: Array.new(20) { "# " * 15 }
      game_loop { rays.draw_with :shimmer }
    end
    builder.finalize_program
    builder.program
  end
end

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
#
# The Advance cartridge's own pixels are read in
# test/lowering/gba/vblank/dsl/test_background_draws_with_cartridge.rb.
class TestBackgroundDrawsWith < Minitest::Test
  include Differential
  include BackgroundDrawsWithGames

  def test_a_background_told_to_draw_with_other_colors_shows_them
    i = game_player.run(a_wall_of_bars { |rays| rays.draw_with :shimmer }, frames: 3)

    assert_equal Color.resolve(:yellow), i.screen.pixel(1, 1), "the first place of the list"
    assert_equal Color.resolve(:white), i.screen.pixel(5, 1), "and the second"
  end

  # Every pixel rather than the two sampled above.
  def test_the_two_backends_agree_about_a_recoloured_layer
    assert_backends_agree(a_wall_of_bars { |rays| rays.draw_with :shimmer }, frames: 3)
  end

  def test_a_list_that_starts_with_a_colour_leaves_the_backdrop_as_it_was
    wall = a_wall_with_gaps_and_lists_that_start_with_a_colour
    shown = game_player.run(wall, frames: 4).screen

    assert_equal Color.resolve(:yellow), shown.pixel(1, 1), "the wall is drawn with the other list"
    assert_equal Color.resolve(:black), shown.pixel(9, 1), "and the gap beside it is still the backdrop"
    assert_backends_agree(wall, frames: 4)
  end

  # A SPRITE IN FRONT OF A WALL THAT SHIMMERS, where nothing scrolls. The wall changes colours
  # every other frame while a blue walker moves a pixel every frame: the walker is drawn on
  # every one of them, the frames the wall changed on included.
  private def a_walker_in_front_of_a_shimmering_wall
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :bar, width: 8, height: 8, data: BAR, colors: OWN
      image :walker, width: 8, height: 8, data: Array.new(64, :blue)
      colors :shimmer, SHIMMER
      tiles :wall, "#" => :bar
      rays = background :rays, tiles: :wall, map: Array.new(20) { "#" * 30 }
      walker = sprite :walker, at: [40, 40]
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        walker.x.add! 1
        rays.draw_with [:shimmer], showing: pass % 2
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_a_sprite_stays_drawn_when_the_wall_behind_it_changes_colors
    (2..7).each do |frames|
      shown = game_player.run(a_walker_in_front_of_a_shimmering_wall, frames: frames).screen.shown

      assert_equal 64, shown.count(Color.resolve(:blue)), "the walker's 64 pixels after #{frames} frames"
    end
  end

  def test_the_console_draws_the_same_walker_and_wall
    (3..7).each { |frames| assert_backends_agree(a_walker_in_front_of_a_shimmering_wall, frames: frames) }
  end

  # Tiles the game paints from a list keep their pixels as places, so a layer of them is
  # recoloured by place the same way. The list paints one tile in the bar's two halves.
  private def a_wall_of_painted_bars
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :ink, OWN
      colors :shimmer, SHIMMER
      canvas = list :canvas, capacity: 32, width: :byte
      repeat(8) { [0x11, 0x11, 0x22, 0x22].each { |two_pixels| canvas.push two_pixels } }
      wall = tiles :wall, from: canvas, count: 1, colors: :ink
      wall.changed
      rays = background :rays, tiles: :wall, map: Array.new(20) { [1] * 30 }
      game_loop { rays.draw_with :shimmer }
    end
    builder.finalize_program
    builder.program
  end

  def test_a_layer_of_painted_tiles_draws_with_other_colors_on_both_backends
    i = game_player.run(a_wall_of_painted_bars, frames: 3)

    assert_equal Color.resolve(:yellow), i.screen.pixel(1, 1), "the first place of the list"
    assert_equal Color.resolve(:white), i.screen.pixel(5, 1), "and the second"
    assert_backends_agree(a_wall_of_painted_bars, frames: 3)
  end

  # Painted again while the other list is in force, the tiles show the colours their places
  # hold now: the whole bar is painted in the second place, so its left half turns from the
  # first place's colour to the second's.
  private def a_wall_of_painted_bars_painted_again
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :ink, OWN
      colors :shimmer, SHIMMER
      canvas = list :canvas, capacity: 32, width: :byte
      repeat(8) { [0x11, 0x11, 0x22, 0x22].each { |two_pixels| canvas.push two_pixels } }
      wall = tiles :wall, from: canvas, count: 1, colors: :ink
      wall.changed
      rays = background :rays, tiles: :wall, map: Array.new(20) { [1] * 30 }
      pass = var :pass, 0
      game_loop do
        rays.draw_with :shimmer
        pass.add! 1
        (pass == 3).then do
          canvas.fill 0x22
          wall.changed
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  # The picture is looked at on every frame, so it is built with the other list before the bar
  # is painted again as well as after.
  def test_painted_tiles_painted_again_show_the_colors_their_places_hold_now
    left_half = []
    i = game_player
    i.each_vblank { left_half << i.screen.pixel(1, 1) }.run(a_wall_of_painted_bars_painted_again, frames: 6)

    assert_includes left_half, Color.resolve(:yellow), "the left half in the first place, before it is painted again"
    assert_equal Color.resolve(:white), i.screen.pixel(1, 1), "the left half, painted in the second place"
    assert_equal Color.resolve(:white), i.screen.pixel(5, 1), "and the right half, as it was"
    assert_backends_agree(a_wall_of_painted_bars_painted_again, frames: 6)
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
    builder.finalize_program
    builder.program
  end

  def test_a_number_the_game_works_out_picks_which_list
    prog = a_wall_that_walks_through_its_lists
    left = ->(frames) { game_player.run(prog, frames: frames).screen.pixel(1, 1) }

    # The display is told at the frame boundary, from the number the pass settled on — as far
    # behind as every picture the framework draws for you (Testing#framework_drawing_lag).
    said = [[:red, "nothing has been said yet, so it is as drawn"], [:orange, "the counter said 0"],
            [:magenta, "...then 1"], [:red, "...then 2, which names no list: as drawn again"],
            [:red, "...then 3, which names none either"]].drop(1 - framework_drawing_lag)
    said.first(4).each.with_index(1) { |(color, why), frames| assert_equal Color.resolve(color), left.call(frames), why }
  end

  # Three scenes each declaring the layer, and each telling it which of 52 lists to draw with: the
  # choice is made once for each scene's layer, one after the other, with a jump for every list.
  # So many jumps that a build naming each by a word, a list's number and a count (the 11th list's
  # 47th, the 1st list's 147th) would name two of them alike.
  def test_three_scenes_choosing_among_fifty_two_lists_draw_with_the_one_named
    lists = (0...52).map { |n| :"shade#{n}" }
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :bar, width: 8, height: 8, data: BAR, colors: OWN
      lists.each_with_index do |name, n|
        colors name, [:transparent, Color.rgb(n % 32, 0, 31 - (n % 32)), Color.rgb(0, n % 32, n / 32)]
      end
      tiles :wall, "#" => :bar
      step = var :step, 0
      showing = var :showing, 0
      3.times do |s|
        scene :"room#{s}" do
          rays = background :rays, tiles: :wall, map: Array.new(20) { "#" * 30 }
          rays.draw_with lists, showing: step
          showing.set!((s + 1) % 3)
        end
      end
      game_loop do
        case_var(:showing) { 3.times { |s| when_val s, :"room#{s}" } }
        step.add! 1
      end
    end
    builder.finalize_program
    shown = game_player.run(builder.program, frames: 6).screen.pixel(1, 1)

    assert_equal Color.rgb(5 - framework_drawing_lag, 0, 26 + framework_drawing_lag), shown
  end

  def test_the_console_walks_the_lists_the_same_way
    assert_backends_agree(a_wall_that_walks_through_its_lists, frames: 4)
  end

  # Told to go back to its own colours, it does — the third form of the verb.
  def test_a_layer_can_be_put_back_in_its_own_colours
    i = game_player.run(a_wall_of_bars { |rays| rays.draw_with :own }, frames: 3)

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
    builder.finalize_program
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

  # --- A LAYER DRAWN FROM SEVERAL LISTS, EVERY ONE OF THEM SWAPPED AT ONCE ---
  #
  # A backdrop with more colours in it than one list holds has its tiles drawn from several,
  # each tile from one. Animating it means stepping every one of those lists to the same
  # version together, by one number, which is what a hash of the layer's own lists says: each
  # list the tiles were drawn from, named, with the versions it walks through.
  #
  # Two tile kinds here, one drawn from :sea and one from :sky, a column of each, so each list
  # shows at a known place.
  SEA = %i[transparent red green].freeze
  SKY = %i[transparent blue white].freeze
  SEA_STEPS = [%i[transparent orange yellow], %i[transparent magenta cyan]].freeze
  SKY_STEPS = [%i[transparent yellow orange], %i[transparent cyan magenta]].freeze

  private def a_backdrop_drawn_from_two_lists
    sea_steps = SEA_STEPS
    sky_steps = SKY_STEPS
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :sea, SEA
      colors :sky, SKY
      sea_steps.each_with_index { |list, i| colors :"sea#{i}", list }
      sky_steps.each_with_index { |list, i| colors :"sky#{i}", list }
      image :water, width: 8, height: 8, data: BAR, colors: :sea
      image :cloud, width: 8, height: 8, data: BAR.map { |c| c == :red ? :blue : :white }, colors: :sky
      tiles :scene, "~" => :water, "o" => :cloud
      backdrop = background :backdrop, tiles: :scene, map: Array.new(20) { ("~" * 15) + ("o" * 15) }
      step = var :step, 0
      game_loop do
        backdrop.draw_with({ sea: %i[sea0 sea1], sky: %i[sky0 sky1] }, showing: step)
        step.add! 1
      end
    end
    builder.finalize_program
    builder.program
  end

  SEA_AT = [1, 1].freeze   # the first place of a :sea tile
  SKY_AT = [121, 1].freeze # the first place of a :sky tile

  def test_one_number_steps_every_list_of_the_layer_together
    prog = a_backdrop_drawn_from_two_lists
    seen = ->(frames) { game_player.run(prog, frames: frames).screen.then { |s| [s.pixel(*SEA_AT), s.pixel(*SKY_AT)] } }

    # As far behind as every picture the framework draws for you (Testing#framework_drawing_lag).
    said = [[%i[red blue], "nothing said yet: as drawn"], [%i[orange yellow], "version 0 of both"],
            [%i[magenta cyan], "version 1 of both"], [%i[red blue], "past the end: both as drawn"],
            [%i[red blue], "further past the end: both as drawn"]].drop(1 - framework_drawing_lag)
    said.first(4).each.with_index(1) do |(colors, why), frames|
      assert_equal colors.map { |name| Color.resolve(name) }, seen.call(frames), why
    end
  end

  def test_the_console_steps_every_list_together_too
    prog = a_backdrop_drawn_from_two_lists
    (1..4).each { |frames| assert_backends_agree(prog, frames: frames) }
  end

  # A tint walks the whole table and then writes each recoloured group back from the list it
  # is really showing — every group of this layer, not only the first.
  private def a_backdrop_that_steps_while_the_screen_reddens
    sea_steps = SEA_STEPS
    sky_steps = SKY_STEPS
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :sea, SEA
      colors :sky, SKY
      sea_steps.each_with_index { |list, i| colors :"sea#{i}", list }
      sky_steps.each_with_index { |list, i| colors :"sky#{i}", list }
      image :water, width: 8, height: 8, data: BAR, colors: :sea
      image :cloud, width: 8, height: 8, data: BAR.map { |c| c == :red ? :blue : :white }, colors: :sky
      tiles :scene, "~" => :water, "o" => :cloud
      backdrop = background :backdrop, tiles: :scene, map: Array.new(20) { ("~" * 15) + ("o" * 15) }
      step = var :step, 0
      hurt = var :hurt, 0
      game_loop do
        backdrop.draw_with({ sea: %i[sea0 sea1], sky: %i[sky0 sky1] }, showing: step)
        step.add! 1
        hurt.approach! 60, 20 # it moves every frame, so the table is rewritten every frame
        tint :red, hurt
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_a_tint_moves_every_list_the_layer_is_drawn_with
    prog = a_backdrop_that_steps_while_the_screen_reddens
    (2..4).each { |frames| assert_backends_agree(prog, frames: frames) }
  end

  # TWO LISTS NAMED APART ARE TWO LISTS, whatever they hold. A game that brings a screen in
  # from white declares every list of it white and walks each to its own colours, so a layer
  # drawn from :sea and :sky starts with both holding the same. Each is still told its own.
  # Given by place, since a list that holds white twice has no other way to say which is which.
  WHITE = %i[transparent white white].freeze
  BAR_PLACES = Array.new(64) { |i| (i % 8) < 4 ? 1 : 2 }.freeze

  private def a_backdrop_of_two_white_lists
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :sea, WHITE
      colors :sky, WHITE
      colors :sea_lit, SEA
      colors :sky_lit, SKY
      image :water, width: 8, height: 8, colors: :sea, places: BAR_PLACES
      image :cloud, width: 8, height: 8, colors: :sky, places: BAR_PLACES
      tiles :scene, "~" => :water, "o" => :cloud
      backdrop = background :backdrop, tiles: :scene, map: Array.new(20) { ("~" * 15) + ("o" * 15) }
      game_loop { backdrop.draw_with({ sea: :sea_lit, sky: :sky_lit }) }
    end
    builder.finalize_program
    builder.program
  end

  def test_two_lists_alike_in_colour_are_each_drawn_with_their_own
    screen = game_player.run(a_backdrop_of_two_white_lists, frames: 3).screen

    assert_equal Color.resolve(:red), screen.pixel(*SEA_AT), ":sea's tiles take :sea_lit"
    assert_equal Color.resolve(:blue), screen.pixel(*SKY_AT), ":sky's tiles take :sky_lit"
  end

  def test_the_console_draws_two_lists_alike_in_colour_apart
    assert_backends_agree(a_backdrop_of_two_white_lists, frames: 3)
  end

  # A tile given the colours themselves, beside tiles given the list by name, is drawn from that
  # list: one list, told one other.
  def test_a_tile_given_a_lists_colours_themselves_is_recoloured_with_it
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :sea, SEA
      colors :sea_dusk, SEA_STEPS[1]
      image :water, width: 8, height: 8, data: BAR, colors: :sea
      image :pool, width: 8, height: 8, data: BAR, colors: SEA
      tiles :scene, "~" => :water, "o" => :pool
      backdrop = background :backdrop, tiles: :scene, map: Array.new(20) { ("~" * 15) + ("o" * 15) }
      game_loop { backdrop.draw_with :sea_dusk }
    end
    builder.finalize_program
    screen = game_player.run(builder.program, frames: 3).screen

    assert_equal Color.resolve(:magenta), screen.pixel(*SEA_AT), "the tile given :sea by name"
    assert_equal Color.resolve(:magenta), screen.pixel(*SKY_AT), "the tile given its colours"
  end

  # ...but where two lists named apart hold those colours, nothing says which.
  def test_a_tile_given_colours_two_lists_hold_is_refused
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :tiled
        colors :sea, WHITE
        colors :sky, WHITE
        colors :sea_lit, SEA
        image :water, width: 8, height: 8, colors: :sea, places: BAR_PLACES
        image :cloud, width: 8, height: 8, colors: :sky, places: BAR_PLACES
        image :mist, width: 8, height: 8, colors: WHITE, places: BAR_PLACES
        tiles :scene, "~" => :water, "o" => :cloud, "." => :mist
        backdrop = background :backdrop, tiles: :scene, map: ["~o."]
        backdrop.draw_with({ sea: :sea_lit })
      end
    end
    assert_match(/:sea and :sky/, err.message)
    assert_match(/colors: :sea/, err.message)
  end

  # ...and a screen brought in the way a Color game brings one in: seven lists of four colours,
  # all white, each walked to its own by one number. Each list's last step is a colour of its
  # own, shown in a column of its own.
  ARRIVING = %i[red green blue yellow cyan magenta orange].freeze

  private def a_screen_of_seven_lists_brought_in_from_white
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      white = %i[white white white white]
      steps = ARRIVING.each_with_index.to_h do |color, i|
        colors :"list#{i}", [:transparent, *white]
        colors :"list#{i}_half", [:transparent, :white, color, :white, color]
        colors :"list#{i}_whole", [:transparent, color, color, color, color]
        image :"tile#{i}", width: 8, height: 8, colors: :"list#{i}", places: Array.new(64) { |p| (p % 4) + 1 }
        [:"list#{i}", [:"list#{i}_half", :"list#{i}_whole"]]
      end
      tiles :screen, ARRIVING.each_index.to_h { |i| [i.to_s, :"tile#{i}"] }
      shown = background :shown, tiles: :screen, map: Array.new(18) { ARRIVING.each_index.map(&:to_s).join * 2 }
      step = var :step, 0
      game_loop do
        shown.draw_with(steps, showing: step)
        step.add! 1
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_seven_lists_alike_in_colour_each_walk_their_own_steps
    # The pass whose number is 1, its last step, as far behind as the framework draws (Testing#framework_drawing_lag).
    screen = game_player.run(a_screen_of_seven_lists_brought_in_from_white, frames: 2 + framework_drawing_lag).screen

    ARRIVING.each_with_index do |color, i|
      assert_equal Color.resolve(color), screen.pixel((i * 8) + 1, 1), "list#{i}'s column at its last step"
    end
  end

  def test_the_console_brings_seven_lists_in_from_white_apart
    (1..3).each { |frames| assert_backends_agree(a_screen_of_seven_lists_brought_in_from_white, frames: frames) }
  end

  # One step of each, with no number: the lists named, and the layer drawn with them from then on.
  def test_each_list_can_be_given_one_other_list
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :sea, SEA
      colors :sky, SKY
      colors :sea_dusk, SEA_STEPS[1]
      image :water, width: 8, height: 8, data: BAR, colors: :sea
      image :cloud, width: 8, height: 8, data: BAR.map { |c| c == :red ? :blue : :white }, colors: :sky
      tiles :scene, "~" => :water, "o" => :cloud
      backdrop = background :backdrop, tiles: :scene, map: Array.new(20) { ("~" * 15) + ("o" * 15) }
      game_loop { backdrop.draw_with({ sea: :sea_dusk }) }
    end
    builder.finalize_program
    prog = builder.program
    screen = game_player.run(prog, frames: 2).screen

    assert_equal Color.resolve(:magenta), screen.pixel(*SEA_AT), "the list named is drawn with its other list"
    assert_equal Color.resolve(:blue), screen.pixel(*SKY_AT), "a list the hash leaves out stays as drawn"
    assert_backends_agree(prog, frames: 2)
  end

  # --- what can go wrong with several lists ---

  private def two_list_backdrop_told(&told)
    Builder.new.instance_eval do
      screen :tiled
      colors :sea, SEA
      colors :sky, SKY
      colors :sea0, SEA_STEPS[0]
      colors :sea1, SEA_STEPS[1]
      colors :sky0, SKY_STEPS[0]
      image :water, width: 8, height: 8, data: BAR, colors: :sea
      image :cloud, width: 8, height: 8, data: BAR.map { |c| c == :red ? :blue : :white }, colors: :sky
      tiles :scene, "~" => :water, "o" => :cloud
      backdrop = background :backdrop, tiles: :scene, map: [("~" * 15) + ("o" * 15)]
      instance_exec(backdrop, &told)
    end
  end

  def test_one_list_for_a_layer_drawn_from_several_says_to_name_each
    err = assert_raises(ArgumentError) { two_list_backdrop_told { |bg| bg.draw_with :sea0 } }

    assert_match(/drawn from 2 lists of colors/, err.message)
    assert_match(/sea: \.\.\., sky: \.\.\./, err.message)
  end

  def test_a_list_none_of_the_tiles_is_drawn_from_is_refused
    err = assert_raises(ArgumentError) { two_list_backdrop_told { |bg| bg.draw_with({ sea0: :sea1 }) } }

    assert_match(/none of its tiles is drawn from :sea0/, err.message)
    assert_match(/:sea, :sky/, err.message)
  end

  def test_lists_with_different_numbers_of_steps_are_refused
    err = assert_raises(ArgumentError) do
      two_list_backdrop_told { |bg| bg.draw_with({ sea: %i[sea0 sea1], sky: %i[sky0] }, showing: 0) }
    end

    assert_match(/the same number of lists of colors/, err.message)
  end
end
