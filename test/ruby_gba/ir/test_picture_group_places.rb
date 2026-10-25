# frozen_string_literal: true

require "test_helper"

# WHERE A SCENE'S GROUPED PICTURES GO IN SPRITE MEMORY. Each picture has one place for as long
# as its scene is up, and it is copied there as one of its groups comes up; two pictures can
# share a place only if no two of their groups can ever be up at once. So what the scene needs
# is what the worst set of groups up together needs, not every group's pictures at once.
class TestPictureGroupPlaces < Minitest::Test
  Places = RubyGBA::IR::PictureGroupPlaces
  Picture = Places::Picture

  private def picture(key, units, groups, even_start: false) = Picture.new(key: key, units: units, even_start: even_start, groups: groups)

  def test_pictures_of_groups_never_up_together_share_a_place
    places = Places.new([picture(:pot, 4, [0]), picture(:bush, 4, [1])], together: [])

    assert_equal 0, places.offset(:pot)
    assert_equal 0, places.offset(:bush)
    assert_equal 4, places.units
  end

  def test_pictures_of_groups_up_together_keep_apart
    places = Places.new([picture(:pot, 4, [0]), picture(:bush, 4, [1])], together: [[0, 1]])

    assert_equal [0, 4], [places.offset(:pot), places.offset(:bush)].sort
    assert_equal 8, places.units
  end

  # A pot in two rooms is up while either is, so it keeps clear of both rooms' other things.
  def test_a_picture_in_two_groups_keeps_clear_of_both
    places = Places.new([picture(:pot, 2, [0, 1]), picture(:bush, 4, [0]), picture(:chest, 4, [1])], together: [])

    assert_equal 0, places.offset(:bush)
    assert_equal 0, places.offset(:chest)
    assert_equal 4, places.offset(:pot)
    assert_equal 6, places.units
  end

  def test_the_biggest_picture_is_placed_first
    places = Places.new([picture(:pot, 2, [0]), picture(:boat, 6, [0])], together: [])

    assert_equal 0, places.offset(:boat)
    assert_equal 6, places.offset(:pot)
  end

  # A picture the machine reads only from an even unit (on the Advance, one stored with 256
  # colours, two units to a tile) is placed at one.
  def test_a_picture_read_from_an_even_unit_starts_on_one
    places = Places.new([picture(:pot, 3, [0]), picture(:boat, 2, [0], even_start: true)], together: [])

    assert_equal 0, places.offset(:pot)
    assert_equal 4, places.offset(:boat)
    assert_equal 6, places.units
  end

  # Three rooms in a row, each up beside the next while the screen slides: the first and the last
  # are never up together, so they share a place, and the scene needs two rooms' room, not three.
  def test_the_scene_needs_only_the_worst_set_up_together
    rooms = [picture(:pot, 4, [0]), picture(:bush, 4, [1]), picture(:chest, 4, [2])]
    places = Places.new(rooms, together: [[0, 1], [1, 2]])

    assert_equal places.offset(:pot), places.offset(:chest)
    refute_equal places.offset(:pot), places.offset(:bush)
    assert_equal 8, places.units
    assert_equal 8, places.worst_units
  end

  # The set whose pictures come to the most, told apart from the room the places take.
  def test_the_worst_set_is_the_one_whose_pictures_come_to_the_most
    rooms = [picture(:pot, 2, [0]), picture(:bush, 2, [1]), picture(:chest, 6, [2])]
    places = Places.new(rooms, together: [[0, 1], [1, 2]])

    assert_equal [1, 2], places.worst_set
    assert_equal 8, places.worst_units
  end

  def test_no_pictures_need_no_room
    assert_equal 0, Places.new([], together: []).units
  end
end
