# frozen_string_literal: true

require "test_helper"
require "differential"

# A CELL OF THE SCENERY CHANGES WHILE THE GAME RUNS.
#
# A background used to be stamped once and never change again. For anything with a world in it
# that is not a small limitation, it is a design tax: a door that opens, a pot that breaks, a
# wall a bomb takes out, a block the player pushes — every one of those is one tile changing,
# and every one of them had to be a sprite instead, out of a budget a game would rather spend
# on things that move.
#
# `room.set_tile col, row, "."` is that, written the way the map was: cell coordinates, and one
# of the tileset's own characters. Nothing here is a tile number, a place in video memory, or a
# moment it is safe to write.
class TestSetTile < Minitest::Test
  include Differential

  SOLID8 = (["########"] * 8).join("\n")

  # A little room with a door in it, and a variable saying whether the door is open.
  def room_program(open_at: 2, col: 3, row: 1)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall, "#" => :red) { SOLID8 }
      image(:floor, "#" => :blue) { SOLID8 }
      tiles :dungeon, "#" => :wall, "." => :floor
      room = background :room, tiles: :dungeon, map: Array.new(6) { "######" }
      frames = var :frames, 0
      game_loop do
        wait_vblank
        frames.add 1
        (frames == open_at).then { room.set_tile col, row, "." }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def pixel_at(cell_col, cell_row, screen)
    screen.pixel((cell_col * 8) + 4, (cell_row * 8) + 4)
  end

  # --- it changes ---

  def test_the_cell_holds_the_new_tile_afterwards
    screen = Reference.new.run(room_program, frames: 4).screen
    assert_equal Color.resolve(:blue), pixel_at(3, 1, screen), "the door is open"
    assert_equal Color.resolve(:red), pixel_at(2, 1, screen), "and its neighbour is untouched"
  end

  def test_the_cell_holds_the_old_tile_before
    screen = Reference.new.run(room_program(open_at: 99), frames: 4).screen
    assert_equal Color.resolve(:red), pixel_at(3, 1, screen), "the door is still shut"
  end

  # The coordinates may be worked out as the game runs, which is the case a game writes: a
  # loop over the cells a bomb reached, a block being pushed.
  def worked_out_coordinates_program
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall, "#" => :red) { SOLID8 }
      image(:floor, "#" => :blue) { SOLID8 }
      tiles :dungeon, "#" => :wall, "." => :floor
      room = background :room, tiles: :dungeon, map: Array.new(6) { "######" }
      where = var :where, 0
      game_loop do
        wait_vblank
        (where < 4).then { room.set_tile where, 2, "."; where.add 1 }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_the_coordinates_may_be_worked_out
    screen = Reference.new.run(worked_out_coordinates_program, frames: 6).screen
    4.times { |c| assert_equal Color.resolve(:blue), pixel_at(c, 2, screen), "cell #{c} opened" }
    assert_equal Color.resolve(:red), pixel_at(4, 2, screen), "and the loop stopped where it said"
  end

  # The console has to write the same cells. A coordinate the game works out is bounds-checked
  # on the way in, and the check has to SKIP the write only when the cell really is off the
  # map — a check that always skipped would leave the console's picture untouched while the
  # oracle's changed.
  def test_both_backends_agree_on_coordinates_worked_out_at_run_time
    assert_backends_agree(worked_out_coordinates_program, frames: 6)
  end

  # A coordinate the game worked out can be off the edge, and then nothing happens — rather
  # than something else being written over. So a bomb at the edge of a room needs no test.
  def test_a_cell_outside_the_map_is_left_alone
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall, "#" => :red) { SOLID8 }
      image(:floor, "#" => :blue) { SOLID8 }
      tiles :dungeon, "#" => :wall, "." => :floor
      room = background :room, tiles: :dungeon, map: Array.new(6) { "######" }
      far = var :far, 900
      game_loop do
        wait_vblank
        room.set_tile far, 1, "."
        room.set_tile(-5, 1, ".")
      end
    end
    builder.emit_pending_functions

    screen = Reference.new.run(builder.program, frames: 3).screen
    assert_equal Color.resolve(:red), pixel_at(0, 1, screen), "nothing else was written over"
  end

  # --- the console draws the same thing ---

  def test_both_backends_agree_after_a_cell_changed
    assert_backends_agree(room_program, frames: 6)
  end

  # A wide map's cells are stored as two squares side by side, so a change in the right half
  # is the one that catches a place worked out with the wrong arithmetic.
  def wide_room_program(col)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall, "#" => :red) { SOLID8 }
      image(:floor, "#" => :blue) { SOLID8 }
      tiles :dungeon, "#" => :wall, "." => :floor
      room = background :room, tiles: :dungeon, map: Array.new(32) { "#" * 64 }
      opened = var :opened, 0
      game_loop do
        wait_vblank
        (opened == 0).then { room.set_tile col, 1, "."; opened.set 1 }
        room.scroll_to 256, 0
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_cell_in_a_wide_maps_second_square_changes
    screen = Reference.new.run(wide_room_program(35), frames: 4).screen
    assert_equal Color.resolve(:blue), pixel_at(3, 1, screen),
                 "column 35, seen from a scroll of 256, is the fourth cell on screen"
  end

  def test_both_backends_agree_on_a_wide_maps_second_square
    assert_backends_agree(wide_room_program(35), frames: 6)
  end

  # --- friendly errors ---

  def test_a_tile_the_background_does_not_have_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      builder = Builder.new
      builder.instance_eval do
        screen :tiled
        image(:wall, "#" => :red) { SOLID8 }
        tiles :dungeon, "#" => :wall
        room = background :room, tiles: :dungeon, map: ["##"]
        game_loop { wait_vblank; room.set_tile 0, 0, "?" }
      end
    end
    assert_match(/:room/, error.message)
    assert_match(/"\?"/, error.message, "it names what was asked for")
    assert_match(/"#"/, error.message, "and what it can be")
  end

  # Every tile of the tileset is shipped whether the map used it or not, so a door can be
  # drawn in the tileset and only ever appear once something opens it. That is the shape a
  # game writes, and it must not need a decoy cell somewhere off screen.
  def test_a_tile_the_map_never_used_can_still_be_put_somewhere
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall, "#" => :red) { SOLID8 }
      image(:floor, "#" => :blue) { SOLID8 }
      tiles :dungeon, "#" => :wall, "." => :floor
      room = background :room, tiles: :dungeon, map: Array.new(6) { "######" } # no floor anywhere
      game_loop { wait_vblank; room.set_tile 1, 1, "." }
    end
    builder.emit_pending_functions

    screen = Reference.new.run(builder.program, frames: 3).screen
    assert_equal Color.resolve(:blue), pixel_at(1, 1, screen)
  end

  def test_changing_a_cell_of_a_bitmap_background_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      builder = Builder.new
      builder.instance_eval do
        screen :bitmap
        image(:wall, "#" => :red) { SOLID8 }
        tiles :dungeon, "#" => :wall
        room = background :room, tiles: :dungeon, map: ["##"]
        game_loop { wait_vblank; room.set_tile 0, 0, "#" }
      end
    end
    assert_match(/screen :bitmap/, error.message)
    assert_match(/blit/, error.message, "it says what to do instead")
  end
end
