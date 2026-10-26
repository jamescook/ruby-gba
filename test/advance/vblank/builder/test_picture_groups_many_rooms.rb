# frozen_string_literal: true

require "test_helper"
require "differential"
require "many_rooms_game"

# A GAME OF MANY ROOMS WITH ITS PICTURES GROUPED BY ROOM, played the way a player plays it:
# walking across a grid of rooms, the next room's things sliding in while the screen slides, and
# the last room's going once the slide has ended. Every room's pictures would not fit in sprite
# memory at once, and the game builds and draws each room's things right on the frame they come
# up, on every lowering of the Advance's game (see ManyRoomsGame). Its pictures have fifteen
# colours, and two of its rooms need more tiles than a Game Boy Color holds, so it is the Advance's
# alone; test/vblank/ir/backends/gbc/test_gbc_picture_groups.rb walks rooms sized for the Color.
class TestPictureGroupsManyRooms < Minitest::Test
  include Differential

  # A picture read at a frame shows the pass before it (see "Which frame's numbers the picture was
  # drawn from" in the testing rules), so the frames are one past these passes: inside the first
  # room; the first pass of the slide right, and the middle of it; the first pass in the next room,
  # once the old room's things have gone; the middle of the slide down, which comes after two
  # slides right, from room 2 to room 8; and the middle of the last slide, down again, to room 21.
  PASSES = [3, 6, 8, 10, 27, 58].freeze

  def test_a_walk_across_the_rooms_draws_each_room_as_it_comes_up
    assert_backends_agree(ManyRoomsGame.program, frames: PASSES.map { |pass| pass + 1 }, name: "ROOMS")
  end

  # In the middle of the slide from room 1 to room 2, the pots drawn are the two rooms' pots and
  # no other room's: the ones of room 1 leaving, the ones of room 2 coming in.
  def test_in_a_slide_the_two_rooms_things_are_drawn
    player = game_player
    player.run(ManyRoomsGame.program, frames: 18)
    pots = ManyRoomsGame::POT_PICTURES

    assert_equal (pots[3, 3] + pots[6, 3]).sort, player.sprites(:pot).map(&:picture).sort
  end
end
