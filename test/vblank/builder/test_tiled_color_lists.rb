# frozen_string_literal: true

require "test_helper"
require "differential"

# A BACKGROUND TILE DRAWN BY PLACE FROM A NAMED LIST OF FOUR COLOURS — the way a cartridge made
# for the Color draws its screens: a palette of four, and each tile's pixels numbers into it. A
# tile that draws no see-through pixel (no place 0) keeps all four of its list's colours, and
# every tile naming the same list is drawn from one palette, so a screen of eight such lists fits
# the Color's eight. Played on every lowering, the picture checked against the console's.
class TestTiledColorLists < Minitest::Test
  include Differential

  # An 8×8 tile drawn in all four places of its list: a quarter of the tile each.
  QUARTERS = Array.new(64) { |i| 1 + ((i % 8) / 4) + (2 * ((i / 8) / 4)) }.freeze

  # Four colours of a list a game declares, place 0 being see-through, as a cartridge's palette is
  # handed over: no two lists alike, and black in each unless +without_black+.
  private def list_colors(n, without_black: false)
    own = [rgb_of(31, 31 - n, 4 * n), rgb_of(4 * n, 31, 8), rgb_of(n, 2 * n, 31)]
    [:transparent, *own, without_black ? rgb_of(20, 20, 20 - n) : 0]
  end

  private def rgb_of(r, g, b) = VBlank::Graphics::Color.rgb(r, g, b)

  # A tiled screen of +count+ lists, each drawing one tile of all four of its colours in a column of
  # its own, the rest of the screen left empty. +lists+ makes each list's colours. +drawn_with+, a
  # list of colours, is one the background is drawn with instead of its own every frame.
  private def lists_game(count, lists: ->(n) { list_colors(n) }, drawn_with: nil)
    colored = (0...count).map { |n| lists.call(n) }
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colored.each_with_index do |list, n|
        colors :"list#{n}", list
        image :"tile#{n}", width: 8, height: 8, colors: :"list#{n}", places: QUARTERS
      end
      colors :other, drawn_with if drawn_with
      tiles :set, colored.each_index.to_h { |n| [n.to_s, :"tile#{n}"] }
      row = colored.each_index.map(&:to_s).join
      board = background :board, tiles: :set, map: Array.new(4) { row }
      game_loop do
        board.draw_with :other if drawn_with
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  # A tiled screen of one tile from each of +lists+ (by name => colours) drawn by +places+, side by
  # side, every frame drawn with +drawn_with+ (by name => a list of colours for each).
  private def recolored_game(lists, places, drawn_with)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      lists.each do |name, list|
        colors name, list
        image :"#{name}_tile", width: 8, height: 8, colors: name, places: places
      end
      drawn_with.each { |name, list| colors :"#{name}_dusk", list }
      tiles :set, lists.keys.each_with_index.to_h { |name, n| [n.to_s, :"#{name}_tile"] }
      board = background :board, tiles: :set, map: Array.new(4) { (0...lists.size).map(&:to_s).join }
      game_loop do
        board.draw_with(drawn_with.keys.to_h { |name| [name, :"#{name}_dusk"] })
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_tile_keeps_all_four_colours_of_its_list
    assert_backends_agree(lists_game(1), frames: 3, name: "FOUR")
  end

  def test_eight_lists_fill_the_eight_palettes
    assert_backends_agree(lists_game(8), frames: 3, name: "EIGHT")
  end

  # A LIST WITH NO BLACK IN IT, the first the screen draws from: the empty cells around the tiles
  # still show black, the colour nothing drawn is on every console.
  def test_an_empty_cell_beside_a_list_with_no_black_is_still_black
    game = lists_game(2, lists: ->(n) { list_colors(n, without_black: true) })

    assert_backends_agree(game, frames: 3, name: "NOBLACK")
    assert_equal 0, game_player.run(game, frames: 3).screen.pixel(100, 100)
  end

  # The first list has no black and the seven after it have: the eight still fit, since a list
  # with black can be the one an empty cell is drawn from.
  def test_eight_lists_fit_when_the_first_has_no_black
    game = lists_game(8, lists: ->(n) { list_colors(n, without_black: n.zero?) })

    assert_backends_agree(game, frames: 3, name: "FIRSTNOBLK")
  end

  # DRAWN WITH ANOTHER LIST, each place shows that list's colour at the same place — black
  # included, which turns white here — while the empty cells around the tiles stay black.
  def test_a_tile_drawn_with_another_list_swaps_place_for_place
    other = [:transparent, rgb_of(2, 20, 2), rgb_of(20, 2, 20), rgb_of(2, 2, 20), rgb_of(31, 31, 31)]
    game = lists_game(1, drawn_with: other)
    seen = game_player.run(game, frames: 3).screen

    assert_backends_agree(game, frames: 3, name: "SWAPPED")
    assert_equal rgb_of(31, 31, 31), seen.pixel(4, 4), "the place that was black"
    assert_equal 0, seen.pixel(100, 100), "an empty cell"
  end

  # A SCREEN FADED IN FROM WHITE BY STEPPING EIGHT LISTS, the way a cartridge made for the Color
  # fades: each tile's own list is four whites — each list's a little off the others', since two
  # lists of the same colours are one list — and the game draws it with the next of four lists a
  # frame, the last its real colours. The map fills the screen, so no empty cell shows.
  # +scenes+, each with eight lists of its own, taking turns every +switch+ frames; none for one screen.
  # +bare_at+ is a frame a scene with no background of its own takes over at, nil for never.
  private def faded_in_eight(steps: 4, scenes: 0, switch: 6, bare_at: nil)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      [*(0...[scenes, 1].max)].each do |k|
        8.times do |n|
          white = VBlank::Graphics::Color.rgb(31, 31 - k, 31 - n)
          colors :"own#{k}_#{n}", [:transparent, white, white, white, white]
          steps.times do |s|
            colors :"step#{k}_#{n}_#{s}",
                   [:transparent, *(0..3).map { |c| VBlank::Graphics::Color.rgb(31 - (s * 7), (n * 3) + c, (s * c * 2) + k) }]
          end
          image :"tile#{k}_#{n}", width: 8, height: 8, colors: :"own#{k}_#{n}", places: QUARTERS
        end
        tiles :"set#{k}", (0...8).to_h { |n| [n.to_s, :"tile#{k}_#{n}"] }
      end
      row = (0...8).map(&:to_s).join * ((screen_width / 64) + 1)
      map = Array.new((screen_height / 8) + 1) { row }
      step = var :step, 0
      lists = ->(k) { (0...8).to_h { |n| [:"own#{k}_#{n}", (0...steps).map { |s| :"step#{k}_#{n}_#{s}" }] } }
      if scenes.zero?
        board = background :board, tiles: :set0, map: map
        game_loop do
          board.draw_with(lists.call(0), showing: step)
          (step < steps - 1).then { step.add! 1 }
        end
      else
        scenes.times do |k|
          scene(:"screen#{k}") do
            board = background :board, tiles: :"set#{k}", map: map
            board.draw_with(lists.call(k), showing: step)
          end
        end
        scene(:bare) { draw_text "HI", 8, 8, :white }
        state = var :state, 0
        tick = var :tick, 0
        game_loop do
          tick.add! 1
          (step < steps - 1).then { step.add! 1 }
          (tick == switch).then do
            state.set! 1
            step.set! 0
          end
          (tick == bare_at).then { state.set! scenes } if bare_at
          case_var(:state) do
            scenes.times { |k| when_val k, :"screen#{k}" }
            when_val scenes, :bare
          end
        end
      end
    end
    b.finalize_program
    b.program
  end

  def test_eight_lists_on_a_screen_with_no_empty_cell_can_all_be_drawn_with_others
    game = faded_in_eight

    assert_backends_agree(game, frames: [2, 6], name: "FADE8")
    assert_equal VBlank::Graphics::Color.rgb(10, 0, 0), game_player.run(game, frames: 6).screen.pixel(0, 0)
  end

  # Two scenes of eight such lists each: each scene brings its own eight in as it comes up.
  def test_two_scenes_of_eight_lists_drawn_with_others_each_fade_in
    game = faded_in_eight(scenes: 2)

    assert_backends_agree(game, frames: [4, 12], name: "FADE88")
    assert_equal VBlank::Graphics::Color.rgb(10, 0, 1), game_player.run(game, frames: 14).screen.pixel(0, 0)
  end

  # A SCENE WITH NO BACKGROUND OF ITS OWN after them shows nothing but black, the colour of a cell
  # nothing is drawn in, though the scene before it put a list drawn with others first.
  def test_a_bare_scene_after_eight_lists_drawn_with_others_is_black
    game = faded_in_eight(scenes: 2, bare_at: 14)

    assert_equal 0, game_player.run(game, frames: 20).screen.pixel(100, 100)
  end

  # ONE SCENE OF SEVEN SUCH LISTS that takes over a few frames in: before it does, the screen shows
  # cells nothing is drawn in, which are black.
  def test_the_frames_before_a_scene_of_lists_drawn_with_others_are_black
    white = rgb_of(31, 31, 31)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      7.times do |n|
        colors :"own#{n}", [:transparent, white, white, white, VBlank::Graphics::Color.rgb(31, 31, 31 - n)]
        colors :"dusk#{n}", [:transparent, *[0x1F, 0x3E0, 0x7C00, 0x3FF].map { |c| c - n }]
        image :"tile#{n}", width: 8, height: 8, colors: :"own#{n}", places: QUARTERS
      end
      tiles :set, (0...7).to_h { |n| [n.to_s, :"tile#{n}"] }
      row = (0...7).map(&:to_s).join * ((screen_width / 56) + 1)
      state = var :state, -1
      tick = var :tick, 0
      scene(:board) do
        board = background :board, tiles: :set, map: Array.new((screen_height / 8) + 1) { row }
        board.draw_with((0...7).to_h { |n| [:"own#{n}", :"dusk#{n}"] })
      end
      game_loop do
        tick.add! 1
        (tick == 5).then { state.set! 0 }
        case_var(:state) { when_val 0, :board }
      end
    end
    b.finalize_program

    assert_equal 0, game_player.run(b.program, frames: 3).screen.pixel(100, 100)
    assert_backends_agree(b.program, frames: [3, 10], name: "LATE7")
  end

  # TWO LISTS OF THE SAME COLOURS IN ANOTHER ORDER, each drawing a tile: the Color draws both from
  # the same four colours, black first, but drawn with other lists, each place of each shows its
  # own list's colour.
  def test_two_lists_alike_in_colour_each_swap_their_own_places
    red = rgb_of(31, 0, 0)
    green = rgb_of(0, 31, 0)
    blue = rgb_of(0, 0, 31)
    lists = { first: [:transparent, 0, red, green, blue], second: [:transparent, red, 0, green, blue] }
    dusk = { first: [:transparent, rgb_of(31, 31, 31), rgb_of(9, 9, 9), rgb_of(18, 4, 4), rgb_of(4, 18, 4)],
             second: [:transparent, rgb_of(4, 4, 18), rgb_of(25, 25, 0), rgb_of(0, 25, 25), rgb_of(25, 0, 25)] }
    game = recolored_game(lists, QUARTERS, dusk)
    seen = game_player.run(game, frames: 3).screen

    assert_equal rgb_of(31, 31, 31), seen.pixel(0, 0), "the first tile's place 1"
    assert_equal rgb_of(4, 4, 18), seen.pixel(8, 0), "the second tile's place 1"
    assert_backends_agree(game, frames: 3, name: "ALIKE")
  end

  # A TILE WITH SEE-THROUGH PIXELS whose list holds one colour at two places: drawn with another
  # list, the two places show two colours, and the see-through pixels the black nothing is on.
  def test_a_see_through_tile_whose_list_holds_one_colour_twice_swaps_by_place
    white = rgb_of(31, 31, 31)
    see_through_quarters = QUARTERS.map { |place| place - 1 }
    lists = { pale: [:transparent, white, white, rgb_of(10, 10, 10)] }
    dusk = { pale: [:transparent, rgb_of(31, 0, 0), rgb_of(0, 31, 0), rgb_of(0, 0, 31)] }
    game = recolored_game(lists, see_through_quarters, dusk)
    seen = game_player.run(game, frames: 3).screen

    assert_equal 0, seen.pixel(0, 0), "a see-through pixel"
    assert_equal rgb_of(31, 0, 0), seen.pixel(4, 0), "place 1"
    assert_equal rgb_of(0, 31, 0), seen.pixel(0, 4), "place 2"
    assert_backends_agree(game, frames: 3, name: "TWICE")
  end

  # A TILE WITH NO SEE-THROUGH PIXEL FROM A LIST OF FIVE, drawing four of its places, two of them
  # one colour: all four of the Color's palette are its own, and drawn with another list each place
  # shows that list's colour.
  def test_a_tile_of_four_places_from_a_list_of_five_swaps_by_place
    white = rgb_of(31, 31, 31)
    lists = { long: [:transparent, white, white, rgb_of(10, 10, 10), 0, rgb_of(5, 20, 5)] }
    dusk = { long: [:transparent, rgb_of(31, 0, 0), rgb_of(0, 31, 0), rgb_of(0, 0, 31), rgb_of(31, 31, 0), 0] }
    game = recolored_game(lists, QUARTERS, dusk)
    seen = game_player.run(game, frames: 3).screen

    assert_equal rgb_of(31, 0, 0), seen.pixel(0, 0), "place 1"
    assert_equal rgb_of(0, 31, 0), seen.pixel(4, 0), "place 2"
    assert_equal rgb_of(31, 31, 0), seen.pixel(4, 4), "place 4"
    assert_backends_agree(game, frames: 3, name: "FIVE")
  end
end
