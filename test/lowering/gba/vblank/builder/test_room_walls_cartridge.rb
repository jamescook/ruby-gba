# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_room_walls"

# A MOVER IS STOPPED BY THE WALLS OF THE ROOM IT IS STANDING IN, on the Advance's own cartridge:
# what its wall check costs in bytes however many rooms there are, and where the console shows
# the mover come to rest. What every run plays is in test/all/vblank/builder/test_room_walls.rb,
# which keeps the rooms both files play in RoomWallsGames.
class TestRoomWallsCartridge < Minitest::Test
  include RoomWallsGames

  # --- what a room costs ---

  # A bordered room with a scattering of pillars, +seed+ deciding where they fall, so two
  # rooms can differ without anything else about the game changing.
  private def scattered_room(seed)
    r = Random.new(seed)
    (0...10).map do |row|
      (0...20).map do |col|
        edge = row.zero? || col.zero? || row == 9 || col == 19
        edge || r.rand(10).zero? ? "#" : "."
      end.join
    end
  end

  private def blocked_game(room_count)
    maps = (0...room_count).to_h { |i| [:"r#{i}", scattered_room(i)] }
    VBlank.build("ROOMS", console: :gba, code: "BRMS", maker: "01", validate: false,
                  out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:wall_t, "#" => :blue) { SOLID_TILE }
      image(:floor_t, "#" => rgb(8, 8, 8)) { SOLID_TILE }
      image(:hero_t, "#" => :red) { SOLID_TILE }
      tiles :dungeon, "#" => :wall_t, "." => :floor_t, solid: ["#"]
      room = background :room, tiles: :dungeon, map: maps
      hero = sprite :hero_t, at: [16, 16]
      hero.blocked_by room
      game_loop { hero.move(:right, by: 1); hero.move(:down, by: 1) }
    end
  end

  private def check_bytes(rom)
    rom.built.placement.sizes.select { |name, _| name.to_s.include?("tile_collision") }.values.sum
  end

  # THE ONE THAT MATTERS. The map to read is worked out once for the whole check, not once
  # per cell, so a game with sixty-four rooms asks its walls exactly what a game with two
  # asks. Without that the offset would ride on every one of the nine reads a check makes.
  def test_what_a_wall_check_costs_does_not_depend_on_how_many_rooms_there_are
    assert_equal check_bytes(blocked_game(2)), check_bytes(blocked_game(64)),
                 "two rooms and sixty-four must emit the same check"
  end

  # ...and the offset itself is the only thing a second room adds.
  def test_a_second_room_adds_the_offset_and_nothing_else
    one = check_bytes(blocked_game(1))
    many = check_bytes(blocked_game(64))

    assert_operator many, :>, one, "a background with several maps has to pick which one"
    assert_operator many - one, :<, 256, "...and picking it is a fixed handful of instructions"
  end

  # --- on the console ---

  def test_the_console_stops_the_mover_in_the_same_place
    program = rooms(maps: { hall: HALL, cave: CAVE })
    rom = ROM.assemble(GBA.new.lower(program), title: "ROOMS", code: "BROO", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 30)

    assert v.red?(12, 12), "the hero rests flush against the hall's wall (its body at x8..15)"
    assert v.blue?(20, 12), "and the wall is right there at x16"
  end
end
