# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test_background_tile_sets.rb whose games ask for what a Game Boy Color's hardware
# cannot do: show a second background while another is showing, draw a tile in more colours than a
# Color tile holds, or need more different tiles than a Color has room for. So they play on the
# Advance's runs alone.
class TestBackgroundTileSetsOnTheAdvance < Minitest::Test
  include Differential

  RED = Color.resolve(:red)
  GREEN = Color.resolve(:green)
  BLUE = Color.resolve(:blue)
  WHITE = Color.resolve(:white)

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # --- two layers walking between areas together, and back ---

  # A ground and a layer of scenery over its left half, each drawn from both areas' sets,
  # walked to the clearing on the third pass and back to the shrine on the sixth. The two
  # backgrounds change set on the same frame, and the second trip brings the first set back.
  private def walk_out_and_back
    program do
      screen :tiled
      image(:shrine_floor, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:clearing_grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:shrine_arch, "#" => :blue, "." => :transparent) { (["####...."] * 8).join("\n") }
      image(:clearing_tree, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :shrine, "#" => :shrine_floor
      tiles :clearing, "#" => :clearing_grass
      tiles :arches, "#" => :shrine_arch
      tiles :trees, "#" => :clearing_tree
      ground_map = (0...20).map { "#" * 30 }
      scenery_map = (0...20).map { ("#" * 15) + (" " * 15) }
      ground = background :ground, tiles: { shrine: :shrine, clearing: :clearing },
                                   map: { shrine: { hall: ground_map }, clearing: { glade: ground_map } }
      scenery = background :scenery, tiles: { shrine: :arches, clearing: :trees },
                                     map: { shrine: { hall_arch: scenery_map }, clearing: { glade_trees: scenery_map } }
      where = var :room, 0
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == 3).then { where.set! 1 }
        (pass == 6).then { where.set! 0 }
        ground.show_map where
        scenery.show_map where
      end
    end
  end

  def test_both_layers_are_in_the_clearing_together
    assert_backends_agree(walk_out_and_back, frames: 4, name: "WALKO")
  end

  def test_both_layers_come_back_to_the_shrine
    assert_backends_agree(walk_out_and_back, frames: 8, name: "WALKB")
  end

  # The colours themselves, on both backends: the arch over the floor in the shrine, and
  # the tree over the grass from the frame the walk lands, both on the same frame.
  def test_both_layers_change_area_on_the_same_frame
    [[3, [BLUE, RED]], [4, [WHITE, GREEN]]].each do |frames, want|
      oracle, console, = backend_pictures(walk_out_and_back, frames: frames, name: "WALKF")
      spots = [(12 * 240) + 10, (12 * 240) + 200] # under the solid half of an arch, and the bare ground

      assert_equal [want, want], [spots.map { |at| oracle[at] }, spots.map { |at| console[at] }], "frame #{frames}"
    end
  end

  # --- colours that fit one area at a time and not together ---

  GROUPS = 9 # groups of fifteen colours an area draws from; the console's table holds sixteen

  # An area of GROUPS tiles, each drawn in fifteen colours no other tile uses — so each tile
  # needs a group of sixteen of its own, and two areas together need more than there are.
  private def colorful_tiles(area)
    (0...GROUPS).map do |t|
      colors = (0...15).map { |c| ((((area * GROUPS) + t) * 15) + c + 1) * 97 }
      (0...64).map { |at| colors[at % 15] }
    end
  end

  private def two_colorful_areas(room, tint: nil)
    pictures = { shrine: colorful_tiles(0), clearing: colorful_tiles(1) }
    program do
      screen :tiled
      sets = pictures.to_h do |area, drawn|
        drawn.each_with_index { |data, n| image(:"#{area}_#{n}", width: 8, height: 8, data: data) }
        tiles area, (0...GROUPS).to_h { |n| [n, :"#{area}_#{n}"] }
        [area, area]
      end
      grid = (0...20).map { |row| (0...30).map { |col| (row + col) % GROUPS } }
      ground = background :ground, tiles: sets, map: { shrine: { hall: grid }, clearing: { glade: grid } }
      where = var :room, room
      tint(*tint) if tint
      game_loop { ground.show_map where }
    end
  end

  def test_both_backends_bring_the_other_areas_colours_in
    assert_backends_agree(two_colorful_areas(1), frames: 4, name: "COLB")
  end

  def test_both_backends_draw_the_first_areas_colours
    assert_backends_agree(two_colorful_areas(0), frames: 4, name: "COLA")
  end

  # The game is tinted half way to red the whole time, so the clearing's colours have to
  # arrive tinted, the same as everything already on screen.
  def test_both_backends_bring_the_colours_in_tinted
    assert_backends_agree(two_colorful_areas(1, tint: [:red, 50]), frames: 4, name: "COLT")
  end

  # --- an area that needs every group, beside a background every area shows ---

  UNSHOWN = Color.rgb(31, 0, 31) # each list's see-through entry: a colour no pixel is drawn in

  # A sign every area shows takes a group of its own, so a town of fifteen tiles that share no
  # colours needs every group the scenery's table has, the first one included. Each tile brings
  # its own list, whose see-through entry is a colour of its own. The first group's first entry is
  # the backdrop, which shows along the bottom row where the ground has no tiles: it stays black.
  private def town_of(count)
    keys = ("a"..).first(count)
    lists = keys.each_index.map { |t| (0...15).map { |c| ((t * 15) + c + 1) * 97 } }
    program do
      screen :tiled
      lists.each_with_index do |colors, t|
        image(:"town_#{keys[t]}", width: 8, height: 8, data: (0...64).map { |at| colors[at % 15] },
                                  colors: [UNSHOWN, *colors])
      end
      image(:field_grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:board, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :town, keys.to_h { |key| [key, :"town_#{key}"] }
      tiles :field, "#" => :field_grass
      tiles :signs, "#" => :board
      streets = (0...20).map { |row| row == 19 ? " " * 30 : (0...30).map { |col| keys[(row + col) % count] }.join }
      ground = background :ground, tiles: { town: :town, field: :field },
                                   map: { town: { square: streets }, field: { meadow: ["#" * 30] * 20 } }
      background :sign, tiles: :signs, map: ["#"]
      game_loop { ground.show_map 0 }
    end
  end

  def test_both_backends_draw_a_town_that_needs_every_group
    assert_backends_agree(town_of(15), frames: 4, name: "GRP15")
  end

  # One tile more and the groups run out. Every tile is drawn from fifteen colours, so the error
  # names the groups and the area, not a tile's colours.
  def test_a_town_that_needs_more_groups_than_there_are_is_a_friendly_error
    error = assert_raises(VBlank::BuildError) { GBA.new.lower(town_of(16)) }

    assert_match(/:town/, error.message)
    assert_match(/groups/, error.message)
    refute_match(/more than 15 colors/, error.message)
  end

  # --- sets that fit one at a time and not together ---

  BIG_SET = 1000

  # Tile +n+ of a set: the corner it is marked in drawn in +mark+, and the number drawn in
  # the bits of the rows between. Only the top-left corner is ever marked, so no tile is
  # another one mirrored, and every one is a picture of its own that has to be stored.
  private def numbered_tile(n, mark)
    (0...64).map do |at|
      x = at % 8
      y = at / 8
      next mark if at.zero?
      next :black if [0, 7].include?(x) && [0, 7].include?(y)

      bit = (y * 6) + x - 1
      n[bit % 16].zero? ? :black : :white
    end
  end

  # Two areas of BIG_SET different tiles each: half the console's tile memory apiece, so
  # either fits and both do not. The clearing's tiles carry numbers past the shrine's, so
  # the same place in each set is a different SHAPE — a colour alone would come out right
  # from the wrong set, since a tile names its colours apart from its pixels.
  private def two_big_areas(room)
    pictures = { shrine: 0, clearing: BIG_SET }.to_h do |area, from|
      [area, (0...BIG_SET).map { |n| numbered_tile(from + n, :red) }]
    end
    program do
      screen :tiled
      sets = pictures.to_h do |area, drawn|
        drawn.each_with_index { |data, n| image(:"#{area}_#{n}", width: 8, height: 8, data: data) }
        tiles area, (0...BIG_SET).to_h { |n| [n, :"#{area}_#{n}"] }
        [area, area]
      end
      grid = (0...32).map { |row| (0...32).map { |col| ((row * 32) + col) % BIG_SET } }
      ground = background :ground, tiles: sets, map: { shrine: { hall: grid }, clearing: { glade: grid } }
      where = var :room, room
      game_loop { ground.show_map where }
    end
  end

  def test_both_backends_draw_the_big_clearing_from_its_own_set
    assert_backends_agree(two_big_areas(1), frames: 8, name: "BIGB")
  end

  # A sign every area shows, drawn white and told to draw yellow, over a ground that walks
  # into the clearing: the clearing's colours going in leave the sign yellow.
  private def recolored_sign_while_walking
    program do
      screen :tiled
      image(:shrine_floor, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:clearing_grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:board, width: 8, height: 8, data: [:white] * 64, colors: %i[transparent white])
      colors :lit, %i[transparent yellow]
      tiles :shrine, "#" => :shrine_floor
      tiles :clearing, "#" => :clearing_grass
      tiles :signs, "#" => :board
      grid = (0...20).map { "#" * 30 }
      ground = background :ground, tiles: { shrine: :shrine, clearing: :clearing },
                                   map: { shrine: { hall: grid }, clearing: { glade: grid } }
      sign = background :sign, tiles: :signs, map: ["#"]
      sign.draw_with :lit
      where = var :room, 1
      game_loop { ground.show_map where }
    end
  end

  # --- one background walking between areas in two scenes, beside other scenery ---

  # :ground walks between areas in two scenes, and the first scene shows a banner along the
  # top row in front of it, in colours the second scene has no use for. So the two scenes lay
  # their colours out differently, and :ground is declared between other scenery in one and
  # alone in the other. The first scene walks into the clearing, the second takes over at the
  # shrine and walks into the clearing, and the first comes back and walks home.
  private def walking_beside_a_banner
    program do
      screen :tiled
      solid = (["#" * 8] * 8).join("\n")
      { shrine_floor: :red, clearing_grass: :green, banner_blue: :blue, banner_yellow: :yellow }.each do |name, color|
        image(name, "#" => color) { solid }
      end
      tiles :shrine, "#" => :shrine_floor
      tiles :clearing, "#" => :clearing_grass
      tiles :banner, "#" => :banner_blue, "o" => :banner_yellow
      grid = (0...20).map { "#" * 30 }
      state = var :state, 0
      tick = var :tick, 0
      where = var :room, 0
      ground = lambda do
        background(:ground, tiles: { shrine: :shrine, clearing: :clearing },
                            map: { shrine: { hall: grid }, clearing: { glade: grid } }).show_map where
      end
      scene(:one) do
        ground.call
        background :banner, tiles: :banner, map: ["#o" * 15] + ([" " * 30] * 19)
      end
      scene(:two) { ground.call }
      game_loop do
        tick.add! 1
        (tick == 3).then { where.set! 1 }
        (tick == 6).then do
          state.set! 1
          where.set! 0
        end
        (tick == 8).then { where.set! 1 }
        (tick == 10).then { state.set! 0 }
        (tick == 12).then { where.set! 0 }
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
  end

  def test_a_background_walking_in_two_scenes_keeps_each_scenes_colours_and_depth
    prog = walking_beside_a_banner
    shown = ->(frames) { game_player.run(prog, frames: frames).screen }

    assert_equal [BLUE, GREEN], [shown.call(5).pixel(0, 0), shown.call(5).pixel(0, 8)],
                 "the banner in front of the clearing"
    assert_backends_agree(prog, frames: [2, 5, 7, 9, 11, 14], name: "SETBANR")
  end

  def test_a_recolored_layer_keeps_its_colours_when_an_area_comes_in
    oracle, console, = backend_pictures(recolored_sign_while_walking, frames: 4, name: "SETRC")

    assert_equal [Color.resolve(:yellow)] * 2, [oracle[(2 * 240) + 2], console[(2 * 240) + 2]]
  end
end
