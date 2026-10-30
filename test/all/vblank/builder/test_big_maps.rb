# frozen_string_literal: true

require "test_helper"
require "differential"

# A BACKGROUND WHOSE MAP IS BIGGER THAN THE CONSOLE'S GRID — wider or taller than 64 cells,
# which is a room four screens across and more. The console holds a grid of at most 64x64
# cells for a layer, so the framework keeps the whole map in the cartridge and copies in the
# cells coming into view as the view moves. Nothing in the program says so: the map is
# written at its size and scrolled like any other.
#
# How many cells the Advance's cartridge copies to put a view up, measured by its profiler, is in
# test/lowering/gba/vblank/builder/test_big_maps_cartridge.rb.

# The maps and games both files play. The game blocks call back through `test = self`, so those
# helpers are public.
module BigMapsGames
  KEYS = %w[r g b w].freeze

  private def program(&block)
    b = VBlank::Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A map with no pattern that repeats every 32 or 64 cells, so a column or row left over
  # from another part of the map, or copied to the wrong place, shows as the wrong colour.
  # With +holes+ two cells in three are empty, for a layer the one behind shows through.
  def scrambled(cols, rows, seed: 7, holes: false)
    random = Random.new(seed)
    Array.new(rows) do
      Array.new(cols) { holes && random.rand(3).positive? ? " " : KEYS[random.rand(KEYS.size)] }.join
    end
  end

  def tileset(builder)
    builder.instance_eval do
      image(:r, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:g, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:b, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:w, "#" => :white, "." => :red) { (["####...."] * 4 + ["#" * 8] * 4).join("\n") }
      tiles :ground, "r" => :r, "g" => :g, "b" => :b, "w" => :w
    end
  end

  # A SCENE'S FIRST TAKEOVER, NAMED AT THE END OF THE PASS BEFORE — as a file screen does on START.
  # A menu for ten passes, which names the playing scene at the end of its tenth. The playing scene
  # owns a big room and puts its view 5 columns and 3 rows from the corner from its first pass.
  def named_at_the_end_of_a_pass(builder)
    test = self
    builder.instance_eval do
      screen :tiled
      test.tileset(self)
      pass = var :pass, 0
      var :mode, 0
      scene(:menu) { nil }
      scene(:playing) do
        ground = background :ground, tiles: :ground, map: test.scrambled(100, 90)
        ground.scroll_to 40, 24
      end
      game_loop do
        pass.add! 1
        case_var(:mode) do
          when_val 0, :menu
          when_val 1, :playing
        end
        (pass == 10).then { set! :mode, 1 }
      end
    end
  end
end

class TestBigMaps < Minitest::Test
  include Differential
  include BigMapsGames

  RED = Color.resolve(:red)

  # A view walked across a 100x90 map, +step_x+ and +step_y+ pixels a pass, from +start+.
  private def walk(step_x, step_y, start: [0, 0], map: scrambled(100, 90))
    test = self
    program do
      screen :tiled
      test.tileset(self)
      ground = background :ground, tiles: :ground, map: map
      x = var :view_x, start[0].to_f
      y = var :view_y, start[1].to_f
      game_loop do
        x.add! step_x.to_f
        y.add! step_y.to_f
        ground.scroll_to x.to_i, y.to_i
      end
    end
  end

  def test_a_map_wider_and_taller_than_64_cells_builds
    assert_backends_agree(walk(0, 0), frames: 2, name: "BIG0")
  end

  def test_the_view_shows_the_map_at_walking_pace
    prog = walk(1.25, 1.25)
    [9, 40].each { |frames| assert_backends_agree(prog, frames: frames, name: "BIGW") }
  end

  def test_the_view_shows_the_map_at_four_pixels_a_frame
    prog = walk(4, 3, start: [300, 200])
    [7, 30].each { |frames| assert_backends_agree(prog, frames: frames, name: "BIGF") }
  end

  def test_the_view_shows_the_map_walking_back
    assert_backends_agree(walk(-4, -4, start: [500, 450]), frames: 25, name: "BIGB")
  end

  # Far past the edge of the map nothing is drawn — the backdrop shows — rather than the
  # map coming round again from its other side.
  def test_past_the_edge_of_a_big_map_shows_nothing
    prog = walk(0, 0, start: [-40, -40])
    shown = game_player.run(prog, frames: 2).screen
    refute_includes [RED, Color.resolve(:green), Color.resolve(:blue), Color.resolve(:white)],
                    shown.pixel(10, 10)
    assert_backends_agree(prog, frames: 2, name: "BIGE")
  end

  # A jump far across the map shows the new place on the frame it lands.
  private def jump
    test = self
    program do
      screen :tiled
      test.tileset(self)
      ground = background :ground, tiles: :ground, map: test.scrambled(120, 110)
      pass = var :pass, 0
      x = var :view_x, 0
      y = var :view_y, 0
      game_loop do
        pass.add! 1
        (pass == 4).then { x.set! 700; y.set! 600 }
        ground.scroll_to x, y
      end
    end
  end

  def test_a_jump_shows_the_new_place_on_the_frame_it_lands
    [4, 5, 6].each { |frames| assert_backends_agree(jump, frames: frames, name: "BIGJ") }
  end

  # --- rooms of different sizes, and walking between them ---

  # A small room and a big one on one background. The game walks into the big room on the
  # fourth pass, with the view moved deep into it on the same pass, then walks the view
  # back toward its corner.
  private def rooms
    test = self
    program do
      screen :tiled
      test.tileset(self)
      ground = background :ground, tiles: :ground,
                                   map: { hut: test.scrambled(30, 20, seed: 3), field: test.scrambled(110, 96) }
      pass = var :pass, 0
      room = var :room, 0
      x = var :view_x, 0
      y = var :view_y, 0
      game_loop do
        pass.add! 1
        (pass == 4).then { room.set! 1; x.set! 400; y.set! 300 }
        (pass > 4).then { x.sub! 3; y.sub! 2 }
        ground.show_map room
        ground.scroll_to x, y
      end
    end
  end

  def test_rooms_of_different_sizes_share_one_background
    [3, 4, 5, 12].each { |frames| assert_backends_agree(rooms, frames: frames, name: "BIGR") }
  end

  # The small room is drawn at its own size: past its edge the view shows nothing, so a
  # smaller room does not cost a big one's room in the cartridge either.
  def test_a_small_room_beside_a_big_one_stops_at_its_own_edge
    refute_includes [RED, Color.resolve(:green), Color.resolve(:blue), Color.resolve(:white)],
                    game_player.run(edge_of_hut, frames: 2).screen.pixel(200, 10)
  end

  private def edge_of_hut
    test = self
    program do
      screen :tiled
      test.tileset(self)
      ground = background :ground, tiles: :ground,
                                   map: { hut: test.scrambled(20, 20, seed: 3), field: test.scrambled(110, 96) }
      game_loop { ground.scroll_to 0, 0 }
    end
  end

  # A big room in an area of its own tiles, walked into from a small room of another area.
  private def areas
    test = self
    program do
      screen :tiled
      test.tileset(self)
      image(:moss, "#" => :green, "." => :blue) { (["#.#.#.#."] * 8).join("\n") }
      image(:sand, "#" => :yellow) { (["#" * 8] * 8).join("\n") }
      tiles :wilds, "r" => :moss, "g" => :sand, "b" => :b, "w" => :w
      ground = background :ground, tiles: { shrine: :ground, wilds: :wilds },
                                   map: { shrine: { hall: test.scrambled(30, 20, seed: 5) },
                                          wilds: { woods: test.scrambled(126, 126, seed: 9) } }
      pass = var :pass, 0
      room = var :room, 0
      x = var :view_x, 0
      y = var :view_y, 0
      game_loop do
        pass.add! 1
        (pass == 3).then { room.set! 1; x.set! 600; y.set! 700 }
        (pass > 3).then { x.add! 4; y.add! 1 }
        ground.show_map room
        ground.scroll_to x, y
      end
    end
  end

  def test_a_big_room_of_another_area_comes_in_with_its_tiles
    [2, 3, 4, 10].each { |frames| assert_backends_agree(areas, frames: frames, name: "BIGA") }
  end

  # A scene that takes over again shows its big room from the top, filled whole. The view
  # starts +start+ pixels across and down and moves on from there each pass.
  private def scenes(start: 0)
    test = self
    program do
      screen :tiled
      test.tileset(self)
      var :mode, 0
      pass = var :pass, 0
      scene(:outside) do
        ground = background :ground, tiles: :ground, map: test.scrambled(100, 90)
        x = var :view_x, start
        x.add! 5
        ground.scroll_to x, x
      end
      scene(:inside) { nil }
      game_loop do
        pass.add! 1
        (pass == 6).then { set! :mode, 1 }
        (pass == 8).then { set! :mode, 0 }
        case_var(:mode) do
          when_val 0, :outside
          when_val 1, :inside
        end
      end
    end
  end

  def test_a_scene_coming_back_fills_its_big_room_again
    [5, 9, 11].each { |frames| assert_backends_agree(scenes, frames: frames, name: "BIGS") }
  end

  # THE FRAME THE SCENE COMES BACK ON shows the room's top-left corner: a background put up
  # again is put up as declared, with its view at the corner, and the game's own place for
  # the view reaches the display in the gap after that pass. So the cells brought in as the
  # scene comes back have to be the ones round the corner, wherever the view was left. Here
  # it was left well away from it, and the frame after shows it there again — and left only a
  # few cells from it, where the cells for the game's place are then brought in a strip at a
  # time from the corner's, not all at once.
  def test_the_frame_a_scene_comes_back_shows_its_big_room_from_the_corner
    [200, 24].each do |start|
      left_away = scenes(start: start)
      [7, 8, 9, 10].each { |frames| assert_backends_agree(left_away, frames: frames, name: "BIGC") }
    end
  end

  # ONE NAME, A BIG ROOM IN EACH OF TWO SCENES: :ground is declared in both, each with a big map
  # of its own, and each scene walks its view across its own. The view brought along is the one
  # of the scene up, from its own map.
  private def big_rooms_in_two_scenes
    test = self
    program do
      screen :tiled
      test.tileset(self)
      var :mode, 0
      pass = var :pass, 0
      x = var :view_x, 0
      %i[forest swamp].each_with_index do |name, seed|
        scene(name) do
          ground = background :ground, tiles: :ground, map: test.scrambled(100, 90, seed: seed + 3)
          ground.scroll_to x, x
        end
      end
      game_loop do
        pass.add! 1
        x.add! 6
        (pass == 6).then { set! :mode, 1 }
        (pass == 12).then { set! :mode, 0 }
        case_var(:mode) do
          when_val 0, :forest
          when_val 1, :swamp
        end
      end
    end
  end

  def test_a_name_in_two_scenes_brings_along_the_view_of_its_own_big_room
    [4, 7, 10, 13, 16].each { |frames| assert_backends_agree(big_rooms_in_two_scenes, frames: frames, name: "BIGN") }
  end

  # A scene's first takeover, named at the end of the pass before: both backends draw the same
  # room around the switch. (That its view is filled only once is measured in the cartridge's file.)
  def test_a_first_takeover_named_at_the_end_of_the_pass_before_draws_the_room
    test = self
    prog = program { test.named_at_the_end_of_a_pass(self) }
    [10, 11, 12, 13].each { |frames| assert_backends_agree(prog, frames: frames, name: "BIGF2") }
  end

  # --- walls ---

  # A wall far into the second, bigger room stops a mover there: the walls of each room are
  # read at that room's own place, whatever size the first room is. The view sits over the
  # wall so the console's picture shows where the mover stopped.
  private def wall_deep_in_a_bigger_room
    field = Array.new(100) { "." * 100 }
    field[80] = ("." * 70) + "#" + ("." * 29)
    program do
      screen :tiled
      image(:floor, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:rock, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :ground, "." => :floor, "#" => :rock, solid: ["#"]
      image(:hero_art, "#" => :red) { (["#" * 8] * 8).join("\n") }
      ground = background :ground, tiles: :ground, map: { hut: ["...."] * 4, field: field }
      ground.show_map :field
      hero = sprite :hero_art, at: [(70 * 8) - 20, 80 * 8]
      hero.blocked_by ground
      # The hero stands where the map's wall is, far off the screen, so it is hidden and this
      # stands in the screen at the same place less 500, showing where the hero stopped.
      hero.hide
      marker = sprite :hero_art, at: [0, 40]
      stood = var :stood, 0
      game_loop do
        hero.move :right, by: 2
        stood.set! hero.x
        marker.move_to hero.x - 500, 40
        ground.scroll_to (70 * 8) - 120, (80 * 8) - 80
      end
    end
  end

  def test_a_wall_deep_in_a_bigger_room_stops_a_mover
    assert_equal (70 * 8) - 8, game_player.run(wall_deep_in_a_bigger_room, frames: 30)[:stood]
  end

  def test_both_backends_stop_the_mover_at_that_wall
    assert_backends_agree(wall_deep_in_a_bigger_room, frames: 30, name: "BIGWL")
  end
end
