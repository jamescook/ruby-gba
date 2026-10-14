# frozen_string_literal: true

require "test_helper"
require "differential"

require "stringio"
require_relative "../../examples/meadow"

# The Meadow example (examples/meadow.rb): a hero walks out of a one-screen cabin into a
# meadow of 120x100 cells, far bigger than the console's grid. The streaming itself is
# pinned in test/ruby_gba/builder/test_big_maps.rb; this confirms the example builds, walks
# out the door, and draws the same picture on both backends on the way.
#
# Going through the door is the example's showcase of `pixelate_out` and `pixelate_in`: the
# picture breaks up into blocks, the room is swapped while nobody can read it, and it comes
# back together, with the room's name kept sharp throughout.
#
# WHICH ROOM A PICTURE SHOWS IS READ OFF THE PICTURE, by the name in its corner, and never
# off the game's `room` variable: the room a frame draws is the one the variable held a
# frame before (see "Which frame's numbers the picture was drawn from" in the testing rules).
class TestMeadowExample < Minitest::Test
  include Differential

  WIDTH = 240
  HEIGHT = 160
  WHITE = Color.resolve(:white)
  BIGGEST = Meadow::BIGGEST_BLOCK

  # The picture after each of the first frames of the walk with DOWN held: far enough to
  # reach the cabin door, go through it, and walk a little way down the path.
  def pictures_of_walk_out(frames = 70)
    (1..frames).map do |n|
      screen = Reference.new.hold(:down).run(Meadow.program, frames: n).screen
      Array.new(HEIGHT) { |y| Array.new(WIDTH) { |x| screen.pixel(x, y) } }
    end
  end

  # Is the bottom left of the picture — clear of the hero, wherever he stands in either
  # room, and of the room's name — in blocks of +size+: every pixel the colour at the corner
  # of its block?
  def bottom_in_blocks?(picture, size)
    (96...HEIGHT).all? do |y|
      (0...96).all? { |x| picture[y][x] == picture[y - (y % size)][x - (x % size)] }
    end
  end

  # The sizes of block the bottom left of the picture is in, 1 left out since every
  # picture is in blocks of one pixel. None for a picture as drawn.
  def block_sizes(picture) = (2..BIGGEST).select { |size| bottom_in_blocks?(picture, size) }

  # Where the room's name is: every white pixel, which nothing else in either room is.
  def lettering(picture)
    (0...HEIGHT).to_a.product((0...WIDTH).to_a).select { |y, x| picture[y][x] == WHITE }
  end

  # The walk as its pictures, and the two frames that bound the change: the first one in
  # blocks at all, and the first one whose name is the meadow's.
  def walk_through_door
    pictures = pictures_of_walk_out
    cabin_name = lettering(pictures[2])
    broke_up = pictures.find_index { |picture| block_sizes(picture).any? }
    swapped = pictures.find_index { |picture| lettering(picture) != cabin_name }
    [pictures, broke_up, swapped]
  end

  def test_it_builds_a_rom
    assert_operator Meadow.build_rom(err: StringIO.new).size, :>, 0
  end

  def test_holding_down_walks_out_of_the_cabin_into_the_meadow
    run = Reference.new.hold(:down).run(Meadow.program, frames: 70)
    assert_equal 1, run[:room], "out of the door and into the meadow"
    assert_operator run[:view_y], :>, 0, "the view follows the hero down the path"
  end

  # The door is not a cut any more: the hero stops in it, and the cabin stays the room
  # for the frames the picture takes to break up.
  def test_the_hero_stops_in_the_doorway_while_the_picture_breaks_up
    stopped = (1..50).map { |n| Reference.new.hold(:down).run(Meadow.program, frames: n)[:hero_y] }
                     .each_cons(2).find_index { |before, after| before == after }
    pictures, broke_up, swapped = walk_through_door

    refute_nil stopped, "he stops, though DOWN is still held"
    assert_operator swapped - broke_up, :>=, Meadow::DOOR_FRAMES - 2, "and the cabin is the room for as long as that takes"
    assert_empty block_sizes(pictures[broke_up - 1]), "from a picture that was as drawn"
  end

  # The swap is hidden on both sides: the last picture of the cabin and the first of the
  # meadow are both in the biggest blocks.
  def test_the_room_is_swapped_between_two_pictures_in_the_biggest_blocks
    pictures, _broke_up, swapped = walk_through_door
    last_of_cabin = pictures[swapped - 1]
    first_of_meadow = pictures[swapped]

    assert bottom_in_blocks?(last_of_cabin, BIGGEST), "the cabin's last picture"
    assert bottom_in_blocks?(first_of_meadow, BIGGEST), "and the meadow's first"
    refute_equal last_of_cabin[HEIGHT - 1][0], first_of_meadow[HEIGHT - 1][0], "which is a different room: floor boards, then grass"
  end

  def test_the_picture_comes_back_together_in_the_meadow_a_size_at_a_time
    pictures, _broke_up, swapped = walk_through_door
    part_way = block_sizes(pictures[swapped + 5])

    refute_empty part_way, "part way back it is still in blocks"
    refute_includes part_way, BIGGEST, "but smaller ones"
    assert_empty block_sizes(pictures.last), "and at the end it is as drawn"
  end

  # The name of the room is in a layer the blocks are placed under, so it is readable on
  # every frame of the change, and it changes on the frame the room does.
  def test_the_name_of_the_room_stays_sharp_on_every_frame_of_the_change
    pictures, broke_up, swapped = walk_through_door
    cabin = lettering(pictures[2])
    meadow = lettering(pictures.last)

    refute_empty cabin
    refute_equal cabin, meadow, "the two rooms have different names"
    assert(pictures[broke_up...swapped].all? { |picture| lettering(picture) == cabin }, "CABIN is as drawn while the picture breaks up")
    assert(pictures[swapped..].all? { |picture| lettering(picture) == meadow }, "and MEADOW from the swap on")
  end

  def test_both_backends_draw_the_cabin
    assert_backends_agree(Meadow.program, frames: 3, name: "MEADA")
  end

  # Out of the door: into the blocks, each frame about the swap, the way back, and down the path.
  def test_both_backends_draw_the_walk_into_the_meadow
    _pictures, broke_up, swapped = walk_through_door
    frames = [broke_up + 3, *((swapped - 1)..(swapped + 3)), swapped + 8, 70]

    frames.each { |count| assert_backends_agree(Meadow.program, frames: count, name: "MEADB", keys: [:down]) }
  end
end
