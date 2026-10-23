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
end
