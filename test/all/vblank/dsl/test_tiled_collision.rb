# frozen_string_literal: true

require "test_helper"

# Tiled collision: a tileset marks tiles `solid:`, and a sprite told it's `blocked_by`
# that background stops at those tiles instead of walking through them. The check is
# pure DSL codegen (box overlaps + a guarded move), so both backends run the same IR
# and agree by construction — asserted here on the interpreter oracle and on hardware.
# `can_move?` exposes the same test for manual control.
#
# The hero walking into the wall on the Advance's cartridge, read in the emulator, is in
# test/lowering/gba/vblank/dsl/test_tiled_collision_cartridge.rb.

# The room both files walk the hero through.
module TiledCollisionGames
  include SharedConstants

  # A 10x5-tile room, floor everywhere but one wall tile at cell (4, 2) -> px (32, 16).
  # A red 8x8 hero starts at +hero_at+; +body+ is the per-frame game-loop code.
  private def scene(hero_at:, &body)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall_t,  "#" => :blue) { SOLID_TILE }
      image(:floor_t, "#" => rgb(8, 8, 8)) { SOLID_TILE }
      image(:hero_t,  "#" => :red) { SOLID_TILE }
      tiles :dungeon, "#" => :wall_t, "." => :floor_t, solid: ["#"]
      wall_map = Array.new(5) { |r| (0...10).map { |c| r == 2 && c == 4 ? "#" : "." }.join }
      room = background :room, tiles: :dungeon, map: wall_map
      hero = sprite :hero_t, at: hero_at
      hero.blocked_by room
      instance_exec(hero, &body)
    end
    builder.finalize_program
    builder.program
  end

  # The hero starts at px (16,16) with a wall at px (32,16); holding right, it walks up
  # to the wall and stops flush (its right edge at x32), never entering the wall cell.
  private def walk_into_wall
    scene(hero_at: [16, 16]) do |hero|
      game_loop do
        wait_vblank
        held(:right).then { hero.move :right, by: 2 }
      end
    end
  end
end

class TestTiledCollision < Minitest::Test
  include VBlank::Console::Hardware
  include TiledCollisionGames

  def test_blocked_by_stops_the_sprite_at_a_wall
    s = game_player.input_each_frame { [:right] }.run(walk_into_wall, max_steps: 3_000).screen
    assert_equal Color.resolve(:red),  s.pixel(28, 20), "the hero rests flush against the wall (its body at x24..31)"
    assert_equal Color.resolve(:blue), s.pixel(36, 20), "the wall is right there at x32.."
    refute_equal Color.resolve(:red),  s.pixel(36, 20), "the hero never entered the wall cell"
  end

  # can_move? reports the same test for manual control: at the wall it can't step right,
  # but it can still step left (open floor).
  def test_can_move_reports_whether_a_wall_blocks_the_way
    prog = scene(hero_at: [24, 16]) do |hero| # already flush against the wall at x32
      var :went_right, 0
      var :went_left, 0
      game_loop do
        wait_vblank
        hero.can_move?(:right, by: 2).then { set! :went_right, 1 }
        hero.can_move?(:left, by: 2).then { set! :went_left, 1 }
        halt
      end
    end
    i = game_player.run(prog)
    assert_equal 0, i[:went_right], "can_move?(:right) is false — a wall is directly ahead"
    assert_equal 1, i[:went_left],  "can_move?(:left) is true — that way is open floor"
  end

  # Pressed against the wall on its right, moving down-AND-right, the hero still slides
  # down along it: each axis is checked on its own, so the blocked right step doesn't
  # freeze the free down step. (A single combined check would jam it in place.)
  def test_the_sprite_slides_along_a_wall
    prog = scene(hero_at: [24, 16]) do |hero| # flush against the wall, which spans y16..23
      game_loop do
        wait_vblank
        hero.move 2, 2       # down-right, into the wall to its right
        after(3) { halt }    # after 3 steps the down component has carried it to y22
      end
    end
    s = game_player.run(prog, max_steps: 3_000).screen
    assert_equal Color.resolve(:red), s.pixel(28, 26),
                 "the right step is blocked by the wall, but the down step still slid the hero down"
  end

  # THE WALLS FOLLOW A CHANGED CELL: a door in the wall at (4, 2) opens with set_tile on the
  # tenth pass, and the hero walking right goes through where it stopped before; a wall put
  # down at (8, 2) on the same pass stops it there instead.
  private def with_dungeon_tiles(&body)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall_t, "#" => :blue) { SOLID_TILE }
      image(:floor_t, "#" => rgb(8, 8, 8)) { SOLID_TILE }
      image(:hero_t, "#" => :red) { SOLID_TILE }
      tiles :dungeon, "#" => :wall_t, "." => :floor_t, solid: ["#"]
      instance_exec(sprite(:hero_t, at: [16, 16]), &body)
    end
    builder.finalize_program
    builder.program
  end

  HALL = Ractor.make_shareable(Array.new(5) { |r| (0...10).map { |c| r == 2 && c == 4 ? "#" : "." }.join })

  private def a_door_that_opens
    with_dungeon_tiles do |hero|
      room = background :room, tiles: :dungeon, map: HALL
      hero.blocked_by room
      tick = var :tick, 0
      game_loop do
        wait_vblank
        tick.add! 1
        (tick == 10).then do
          room.set_tile 4, 2, "."
          room.set_tile 8, 2, "#"
        end
        hero.move :right, by: 2
      end
    end
  end

  def test_a_wall_opened_with_set_tile_lets_the_sprite_through_and_one_put_down_stops_it
    prog = a_door_that_opens
    at = ->(frames) { game_player.run(prog, frames: frames).screen }

    assert_equal Color.resolve(:red), at.call(9).pixel(28, 20), "held at the door while it is shut"
    assert_equal Color.resolve(:red), at.call(40).pixel(60, 20), "through the open door, flush against the new wall at x64"
    assert_equal Color.resolve(:blue), at.call(40).pixel(68, 20), "the new wall"
  end

  # ...and a cell changed and then put back as declared, by the map coming up again, puts the
  # walls back too: a room's door opens, the hero leaves for another room and comes back, and
  # the door is shut again and holds it.
  private def a_door_that_shuts_again
    with_dungeon_tiles do |hero|
      room = background :room, tiles: :dungeon, map: { hall: HALL, yard: Array.new(5) { "." * 10 } }
      hero.blocked_by room
      tick = var :tick, 0
      where = var :where, 0
      game_loop do
        wait_vblank
        tick.add! 1
        (tick == 3).then { room.set_tile 4, 2, "." }
        (tick == 5).then { where.set! 1 }
        (tick == 7).then do
          where.set! 0
          hero.x.set! 16
        end
        room.show_map where
        (tick > 8).then { hero.move :right, by: 2 }
      end
    end
  end

  def test_a_map_put_up_again_puts_its_walls_back
    shown = game_player.run(a_door_that_shuts_again, frames: 30).screen

    assert_equal Color.resolve(:blue), shown.pixel(36, 20), "the door is shut again"
    assert_equal Color.resolve(:red), shown.pixel(28, 20), "and holds the hero back"
  end

  # ...and the same for a scene taking over again: its room goes up as declared, door shut.
  private def a_door_shut_again_by_its_scene
    with_dungeon_tiles do |hero|
      tick = var :tick, 0
      var :state, 0
      scene(:hall) do
        room = background :room, tiles: :dungeon, map: HALL
        hero.blocked_by room
        (tick == 3).then { room.set_tile 4, 2, "." }
        (tick > 8).then { hero.move :right, by: 2 }
      end
      scene(:away) { background :yard, tiles: :dungeon, map: Array.new(5) { "." * 10 } }
      game_loop do
        wait_vblank
        tick.add! 1
        (tick == 5).then { set! :state, 1 }
        (tick == 7).then do
          set! :state, 0
          hero.x.set! 16
        end
        case_var(:state) do
          when_val 0, :hall
          when_val 1, :away
        end
      end
    end
  end

  def test_a_scene_taking_over_again_puts_its_walls_back
    shown = game_player.run(a_door_shut_again_by_its_scene, frames: 30).screen

    assert_equal Color.resolve(:blue), shown.pixel(36, 20), "the door is shut again"
    assert_equal Color.resolve(:red), shown.pixel(28, 20), "and holds the hero back"
  end

  # ONE NAME IN TWO SCENES, WALLS OF ITS OWN IN EACH: each level declares a :world with a
  # wall in a different column, and the hero walking right in each level is stopped by that
  # level's own wall.
  private def two_levels_with_walls_apart
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall_t, "#" => :blue) { SOLID_TILE }
      image(:floor_t, "#" => rgb(8, 8, 8)) { SOLID_TILE }
      image(:hero_t, "#" => :red) { SOLID_TILE }
      tiles :dungeon, "#" => :wall_t, "." => :floor_t, solid: ["#"]
      state = var :state, 0
      tick = var :tick, 0
      hero = sprite :hero_t, at: [16, 16]
      { one: 4, two: 8 }.each do |level, wall_at|
        scene(level) do
          world = background :world, tiles: :dungeon, map: Array.new(5) { ("." * wall_at) + "#" + ("." * 10) }
          hero.blocked_by world
          hero.move :right, by: 2
        end
      end
      game_loop do
        tick.add! 1
        (tick == 20).then do
          state.set! 1
          hero.x.set! 16
        end
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_a_name_declared_in_two_scenes_stops_the_sprite_at_each_scenes_own_walls
    prog = two_levels_with_walls_apart
    at = ->(frames) { game_player.run(prog, frames: frames).screen }

    assert_equal Color.resolve(:red), at.call(18).pixel(28, 20), "flush against the first level's wall, at x32"
    assert_equal Color.resolve(:blue), at.call(18).pixel(36, 20), "the first level's wall"
    assert_equal Color.resolve(:red), at.call(40).pixel(60, 20), "flush against the second level's wall, at x64"
  end
end
