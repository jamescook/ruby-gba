# frozen_string_literal: true

require "test_helper"
require "differential"

# A MOVER IS STOPPED BY THE WALLS OF THE ROOM IT IS STANDING IN.
#
# A background with several maps is a game with several rooms, and walking through a
# door is naming one. The walls follow: a cell that is a wall in the hall can be open
# floor in the cave, because the check reads the grid of the map that is really showing.
#
# And WHAT STOPS a mover is said apart from what it SEES. Without `walls:` the walls are
# the tileset's `solid:` tiles, read off the picture, which is what a small game wants.
# With `walls:` they are their own data — which is what a real game's collision is, and
# what lets a map say it has no walls at all.
#
# What the Advance's cartridge shows, and what its wall check costs in bytes, is in
# test/lowering/gba/vblank/builder/test_room_walls_cartridge.rb, which plays the rooms kept here
# in RoomWallsGames.
module RoomWallsGames
  include SharedConstants # Builder and SOLID_TILE, which the game below names from inside the module

  # Two rooms the same size. In the hall, cell (2, 1) is a wall; in the cave that same
  # cell is open floor. A hero starting at cell (1, 1) and walking right is stopped in
  # one room and walks on in the other — from the same program, at the same spot.
  HALL = [".....", "..#..", "....."].freeze
  CAVE = [".....", ".....", "....."].freeze

  private def rooms(maps:, walls: nil, solid: ["#"], start: [8, 8])
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall_t, "#" => :blue) { SOLID_TILE }
      image(:floor_t, "#" => rgb(8, 8, 8)) { SOLID_TILE }
      image(:hero_t, "#" => :red) { SOLID_TILE }
      tiles :dungeon, "#" => :wall_t, "." => :floor_t, solid: solid
      room = background(:room, tiles: :dungeon, map: maps, walls: walls)
      hero = sprite :hero_t, at: start
      hero.blocked_by room
      moved = var :moved, 0
      game_loop do
        wait_vblank
        pressed(:a).then { room.show_map 1 }
        hero.move :right, by: 1
        moved.set! hero.x
      end
    end
    builder.finalize_program
    builder.program
  end
end

class TestRoomWalls < Minitest::Test
  include VBlank::Console::Hardware
  include Differential
  include RoomWallsGames

  # The same two rooms drawn IDENTICALLY, so nothing about the picture says where the
  # walls are. Only `walls:` does.
  PLAIN = [".....", ".....", "....."].freeze
  HALL_WALLS = ["     ", "  #  ", "     "].freeze

  private def walked_to(program, press_a_on: nil)
    game_player.input_each_frame { |f| f == press_a_on ? [:a] : [] }.run(program, frames: 30)[:moved]
  end

  # --- the walls follow the room ---

  # In the hall the hero meets the wall at cell (2,1) — px 16 — and rests flush at x8.
  # Nothing is pressed, so the hall is still showing at the end of the run.
  def test_a_mover_is_stopped_by_the_wall_of_the_room_it_is_in
    assert_equal 8, walked_to(rooms(maps: { hall: HALL, cave: CAVE }))
  end

  # ...and handed the cave, where that same cell is floor, it walks straight through the
  # spot that stopped it. This is the whole feature: one program, one wall test, two rooms.
  def test_the_same_mover_walks_through_that_cell_in_the_other_room
    walked = walked_to(rooms(maps: { hall: HALL, cave: CAVE }), press_a_on: 2)

    assert_operator walked, :>, 8, "the cave has no wall there, so the hero walks on past x8"
  end

  # A background with several maps used to refuse `blocked_by` outright, because the walls
  # were read once while the program was built and would have been the first room's
  # everywhere. That refusal is gone.
  def test_a_background_with_several_maps_accepts_blocked_by
    rooms(maps: { hall: HALL, cave: CAVE })
  end

  # --- walls said apart from the picture ---

  # Both rooms are drawn from plain floor — the picture says nothing about walls at all —
  # and `walls:` puts one in the hall. Nothing about which tile was drawn decides this.
  def test_walls_can_be_their_own_data_rather_than_the_picture
    program = rooms(maps: { hall: PLAIN, cave: PLAIN },
                    walls: { hall: HALL_WALLS }, solid: [])

    assert_equal 8, walked_to(program), "the hall's own wall grid stops the hero"
  end

  # A MAP `walls:` DOES NOT NAME HAS NO WALLS. That is the explicit way to say a room is
  # somewhere you walk anywhere — a fly-over map, a cut-scene tableau, scenery rather than
  # a place — and it is one missing line, not a second background.
  def test_a_map_that_walls_does_not_name_has_none
    program = rooms(maps: { hall: PLAIN, cave: PLAIN },
                    walls: { hall: HALL_WALLS }, solid: [])
    walked = walked_to(program, press_a_on: 2)

    assert_operator walked, :>, 8, "the cave names no walls, so the hero walks anywhere in it"
  end

  # The tileset's `solid:` tiles are still the walls when nothing says otherwise, so every
  # game written before `walls:` existed is untouched.
  def test_without_walls_the_tilesets_solid_tiles_are_still_the_walls
    assert_equal 8, walked_to(rooms(maps: { hall: HALL, cave: CAVE }))
  end

  # A `walls:` key that names no map would silently leave that room walkable, which reads
  # as broken collision rather than as the typo it is.
  def test_walls_naming_a_map_that_does_not_exist_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      rooms(maps: { hall: PLAIN, cave: PLAIN }, walls: { hal: HALL_WALLS })
    end

    assert_match(/no map :hal\b/, err.message)
    assert_match(/walk straight through/, err.message)
  end

  # --- both backends ---

  # Whole-screen, frame by frame, while the hero is still walking — so the path it took
  # through the room is pinned and not only where it ended up.
  def test_both_backends_draw_the_same_rooms_frame_for_frame
    program = rooms(maps: { hall: HALL, cave: CAVE })
    (1..8).each { |f| assert_backends_agree(program, frames: f, name: "ROOMS") }
  end
end
