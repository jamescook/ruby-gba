# frozen_string_literal: true

require "test_helper"
require "differential"

# A BACKGROUND WHOSE MAPS DRAW FROM MORE THAN ONE SET OF TILES, which is how a game moves
# between areas: every room of an area draws from the one set the area loads, and going
# to another area brings that area's set in. Each set fits the console's tile memory on
# its own; the sets together need not.
class TestBackgroundTileSets < Minitest::Test
  include Differential

  RED = Color.resolve(:red)
  GREEN = Color.resolve(:green)
  BLUE = Color.resolve(:blue)
  WHITE = Color.resolve(:white)

  SPOT = [12, 12].freeze

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # Two areas of one room each, drawn from two sets whose first tiles differ only in
  # colour: the shrine's is red and the clearing's green. They land in the same place in
  # tile memory, so the clearing showing green is the clearing's set having been brought in.
  def two_areas(room)
    program do
      screen :tiled
      image(:shrine_floor, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:clearing_grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :shrine, "#" => :shrine_floor
      tiles :clearing, "#" => :clearing_grass
      grid = (0...20).map { "#" * 30 }
      ground = background :ground, tiles: { shrine: :shrine, clearing: :clearing },
                                   map: { shrine: { hall: grid }, clearing: { glade: grid } }
      where = var :room, room
      game_loop { ground.show_map where }
    end
  end

  def pixel(prog, frames: 3)
    Reference.new.run(prog, frames: frames).screen.pixel(*SPOT)
  end

  def test_the_first_areas_room_draws_from_its_own_set
    assert_equal RED, pixel(two_areas(0))
  end

  def test_a_room_of_another_area_draws_from_that_areas_set
    assert_equal GREEN, pixel(two_areas(1))
  end

  def test_both_backends_draw_the_first_area
    assert_backends_agree(two_areas(0), frames: 3, name: "SETA")
  end

  def test_both_backends_bring_the_other_areas_set_in
    assert_backends_agree(two_areas(1), frames: 3, name: "SETB")
  end

  # --- two layers walking between areas together, and back ---

  # A ground and a layer of scenery over its left half, each drawn from both areas' sets,
  # walked to the clearing on the third pass and back to the shrine on the sixth. The two
  # backgrounds change set on the same frame, and the second trip brings the first set back.
  def walk_out_and_back
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

  # A game tinted blue walks into the clearing, and then a fade lifts the tint: the colours
  # put back are the clearing's, not the shrine's it started with.
  def tint_lifted_in_the_clearing
    program do
      screen :tiled
      image(:shrine_floor, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:clearing_grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :shrine, "#" => :shrine_floor
      tiles :clearing, "#" => :clearing_grass
      grid = (0...20).map { "#" * 30 }
      ground = background :ground, tiles: { shrine: :shrine, clearing: :clearing },
                                   map: { shrine: { hall: grid }, clearing: { glade: grid } }
      where = var :room, 1
      pass = var :pass, 0
      tint :blue, 50
      game_loop do
        pass.add! 1
        (pass == 4).then { fade :black, 0 }
        ground.show_map where
      end
    end
  end

  # A sign every area shows, drawn white and told to draw yellow, over a ground that walks
  # into the clearing: the clearing's colours going in leave the sign yellow.
  def recolored_sign_while_walking
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

  def test_a_recolored_layer_keeps_its_colours_when_an_area_comes_in
    oracle, console, = backend_pictures(recolored_sign_while_walking, frames: 4, name: "SETRC")

    assert_equal [Color.resolve(:yellow)] * 2, [oracle[(2 * 240) + 2], console[(2 * 240) + 2]]
  end

  def test_lifting_a_tint_puts_back_the_colours_of_the_area_walked_into
    oracle, console, = backend_pictures(tint_lifted_in_the_clearing, frames: 8, name: "SETFD")
    at = (12 * 240) + 12

    assert_equal [GREEN, GREEN], [oracle[at], console[at]]
  end

  # A scene that walked into the clearing, handed over to a title screen with no scenery
  # and came back, is put up as declared: the shrine, with the shrine's tiles in.
  def leave_and_return
    program do
      screen :tiled
      image(:shrine_floor, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:clearing_grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :shrine, "#" => :shrine_floor
      tiles :clearing, "#" => :clearing_grass
      grid = (0...20).map { "#" * 30 }
      var :mode, 1
      pass = var :pass, 0
      scene(:title) { nil }
      scene(:play) do
        ground = background :ground, tiles: { shrine: :shrine, clearing: :clearing },
                                     map: { shrine: { hall: grid }, clearing: { glade: grid } }
        (pass == 2).then { ground.show_map 1 }
      end
      game_loop do
        pass.add! 1
        (pass == 4).then { set! :mode, 0 }
        (pass == 6).then { set! :mode, 1 }
        case_var(:mode) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
  end

  def test_a_scene_that_comes_back_shows_its_first_area
    assert_equal [GREEN, RED], [pixel(leave_and_return, frames: 3), pixel(leave_and_return, frames: 9)]
  end

  def test_both_backends_put_the_first_area_back
    assert_backends_agree(leave_and_return, frames: 9, name: "SETRT")
  end

  # --- walls in the area the hero is in ---

  # The clearing has a row of trees across the hero's path and the shrine has none. The hero
  # walks right for a while in whichever area it is in, and stops at the trees only there.
  def walk_right_in(room)
    program do
      screen :tiled
      image(:floor, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:grass, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:tree, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :shrine, "#" => :floor
      tiles :clearing, "#" => :grass, "T" => :tree, solid: ["T"]
      hall = (0...20).map { "#" * 30 }
      glade = (0...20).map { ("#" * 15) + "T" + ("#" * 14) }
      ground = background :ground, tiles: { shrine: :shrine, clearing: :clearing },
                                   map: { shrine: { hall: hall }, clearing: { glade: glade } }
      hero = sprite :guy, at: [80, 40]
      hero.blocked_by ground
      ground.show_map room
      stood = var :stood, 0
      game_loop do
        hero.move :right, by: 2
        stood.set! hero.x
      end
    end
  end

  def test_the_trees_of_the_clearing_stop_the_hero_and_the_shrine_has_none
    stood = [0, 1].map { |room| Reference.new.run(walk_right_in(room), frames: 30)[:stood] }

    assert_operator stood[0], :>, 120, "the shrine lets the hero walk on"
    assert_equal 112, stood[1], "the clearing's trees, at column 15, stop the hero's right edge at 120"
  end

  # --- what it refuses ---

  def refused(error = ArgumentError, &block)
    assert_raises(error) { RubyGBA::IR::Backends::GBA.new.lower(program(&block)) }
  end

  def test_maps_not_under_the_names_of_the_sets_are_refused
    error = refused do
      screen :tiled
      image(:a, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :one, "#" => :a
      tiles :two, "#" => :a
      background :ground, tiles: { shrine: :one, clearing: :two }, map: { hall: ["#"] }
    end

    assert_match(/under the same names/, error.message)
  end

  def test_two_maps_with_one_name_are_refused
    error = refused do
      screen :tiled
      image(:a, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :one, "#" => :a
      tiles :two, "#" => :a
      background :ground, tiles: { shrine: :one, clearing: :two },
                          map: { shrine: { room: ["#"] }, clearing: { room: ["#"] } }
    end

    assert_match(/two maps named :room/, error.message)
  end

  def test_set_tile_on_a_walking_background_is_refused
    error = refused do
      screen :tiled
      image(:a, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :one, "#" => :a
      tiles :two, "#" => :a
      ground = background :ground, tiles: { shrine: :one, clearing: :two },
                                   map: { shrine: { hall: ["#"] }, clearing: { glade: ["#"] } }
      game_loop { ground.set_tile 0, 0, "#" }
    end

    assert_match(/use show_map/, error.message)
  end

  def test_areas_whose_tiles_are_different_sizes_are_refused
    error = refused do
      screen :tiled
      image(:small, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:large, "#" => :red) { (["#" * 16] * 16).join("\n") }
      tiles :one, "#" => :small
      tiles :two, "#" => :large
      background :ground, tiles: { shrine: :one, clearing: :two },
                          map: { shrine: { hall: ["#"] }, clearing: { glade: ["#"] } }
    end

    assert_match(/tiles of one size/, error.message)
  end

  def test_a_walking_background_that_turns_is_refused
    error = refused(RubyGBA::IR::Backends::GBA::LoweringError) do
      screen :rotozoom
      image(:a, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :one, "#" => :a
      tiles :two, "#" => :a
      square = (0...16).map { "#" * 16 }
      background :ground, tiles: { shrine: :one, clearing: :two },
                          map: { shrine: { hall: square }, clearing: { glade: square } }
      game_loop { nil }
    end

    assert_match(/turns or resizes, and it walks between areas/, error.message)
  end

  def test_a_walking_background_with_painted_tiles_is_refused
    error = refused(RubyGBA::IR::Backends::GBA::LoweringError) do
      screen :tiled
      image(:a, "#" => :red) { (["#" * 8] * 8).join("\n") }
      colors :ink, %i[transparent white]
      canvas = list :canvas, capacity: 32, width: :byte
      repeat(32) { canvas.push 0 }
      tiles :box, from: canvas, count: 1, colors: :ink
      tiles :two, "#" => :a
      background :ground, tiles: { shrine: :box, clearing: :two },
                          map: { shrine: { hall: [[1]] }, clearing: { glade: ["#"] } }
      game_loop { nil }
    end

    assert_match(/painted from a list/, error.message)
  end

  def test_walking_backgrounds_that_start_in_different_areas_are_refused
    error = refused(RubyGBA::IR::Backends::GBA::LoweringError) do
      screen :tiled
      image(:a, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :one, "#" => :a
      tiles :two, "#" => :a
      background :ground, tiles: { shrine: :one, clearing: :two },
                          map: { shrine: { hall: ["#"] }, clearing: { glade: ["#"] } }
      background :scenery, tiles: { clearing: :two, shrine: :one },
                           map: { clearing: { trees: ["#"] }, shrine: { arch: ["#"] } }
      game_loop { nil }
    end

    assert_match(/start in the same area/, error.message)
  end

  # --- colours that fit one area at a time and not together ---

  GROUPS = 9 # groups of fifteen colours an area draws from; the console's table holds sixteen

  # An area of GROUPS tiles, each drawn in fifteen colours no other tile uses — so each tile
  # needs a group of sixteen of its own, and two areas together need more than there are.
  def colorful_tiles(area)
    (0...GROUPS).map do |t|
      colors = (0...15).map { |c| ((((area * GROUPS) + t) * 15) + c + 1) * 97 }
      (0...64).map { |at| colors[at % 15] }
    end
  end

  def two_colorful_areas(room, tint: nil)
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
  def numbered_tile(n, mark)
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
  def two_big_areas(room)
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

  def test_two_sets_too_big_to_share_the_memory_build
    refute_empty RubyGBA::IR::Backends::GBA.new.lower(two_big_areas(0))
  end

  def test_both_backends_draw_the_big_clearing_from_its_own_set
    assert_backends_agree(two_big_areas(1), frames: 8, name: "BIGB")
  end
end
