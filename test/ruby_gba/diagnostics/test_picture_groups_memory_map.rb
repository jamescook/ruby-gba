# frozen_string_literal: true

require "test_helper"
require "many_rooms_game"

# A SCENE'S PICTURE GROUPS IN THE MAP OF SPRITE MEMORY. A grouped picture has one place there,
# shared with pictures whose groups are never up with its own, and is copied in as one of its
# groups comes up. So what a scene needs for its groups is what the worst set of groups up
# together needs, and that set is the one to make smaller when the scene does not fit. The map
# says, for each set of groups: where its room is, each group's pictures and places and what
# bringing it up copies, what each set up together comes to, and which of those is the worst.
#
# The interpreter has no sprite memory, so this is the GBA lowering's report alone.
class TestPictureGroupsMemoryMap < Minitest::Test
  INKS = (1..15).map { |i| Color.rgb(i * 2, 31 - (i * 2), 10) }.freeze
  PICTURES = (0...40).map { |n| :"art_#{n}" }.freeze

  # A 64x64 picture filling its square and differing from every other: 2048 bytes, 64 tiles of
  # sprite memory, stored the small way (fifteen colours).
  def self.art(number)
    (0...64).flat_map do |y|
      (0...64).map do |x|
        next INKS[(number >> (x % 8)) & 1] if y.zero?

        INKS[((x * 5) + (y * 3) + number) % 15]
      end
    end
  end

  TILES = 64 # one picture's tiles
  BYTES = TILES * 32
  CONSOLE_SPRITE_BYTES = 32_768 # the console's sprite memory

  # A badge in every scene, and a harbor of three rooms in a row, each up beside the next while
  # the screen slides: two pictures in the first room, one in the second, three in the third. A
  # pool of gulls can show any room's.
  private def harbor
    art = TestPictureGroupsMemoryMap.method(:art)
    RubyGBA.build("HARBOR", out: StringIO.new, err: StringIO.new) do
      screen :tiled
      PICTURES.each_with_index { |name, n| image name, width: 64, height: 64, data: art.call(n) }
      sprite :badge, facing: { still: :art_0 }, at: [0, 0]
      var :state, 0
      scene(:harbor) do
        room = var :room, 0
        rooms = picture_groups :rooms, { 0 => %i[art_1 art_2], 1 => %i[art_3], 2 => %i[art_4 art_5 art_6] },
                               up_together: [[0, 1], [1, 2]]
        gulls = pool :gull, x: 0, y: 0, look: 0, capacity: 3, facing: PICTURES[1..6].to_h { |name| [name, name] }
        sprite :buoy, facing: { still: :art_3 }, at: [100, 100]
        rooms.show room
        gulls.each { |gull| gull.face PICTURES[1..6], showing: gull.look }
      end
      game_loop { case_var(:state) { when_val 0, :harbor } }
    end
  end

  private def harbor_screen = harbor.sprite_memory.screens.find { |screen| screen.scene == :harbor }

  def test_each_group_says_its_pictures_what_bringing_it_up_copies_and_where_they_go
    rooms = harbor_screen.picture_groups.fetch(0)
    groups = rooms.groups.to_h { |group| [group.number, group] }

    assert_equal :rooms, rooms.name
    assert_equal %i[art_1 art_2], groups.fetch(0).pictures
    assert_equal [2 * BYTES, BYTES, 3 * BYTES], groups.values_at(0, 1, 2).map(&:bytes)
    places = groups.values.flat_map(&:places).to_h
    assert_equal places.fetch(:art_1), places.fetch(:art_4), "rooms never up together share a place"
    refute_equal places.fetch(:art_3), places.fetch(:art_1)
    assert_operator places.values.min, :>=, rooms.first_tile
  end

  # The second room with the third is four pictures; the first with the second is three.
  def test_the_worst_set_up_together_is_named
    rooms = harbor_screen.picture_groups.fetch(0)

    assert_equal [[[0, 1], 3 * BYTES], [[1, 2], 4 * BYTES]], rooms.up_together.map { |set| [set.groups, set.bytes] }
    assert_equal [1, 2], rooms.worst.groups
    assert_equal 4 * BYTES, rooms.worst.bytes
    assert_equal 4 * BYTES, rooms.bytes, "the room the places take, here no more than the worst set"
  end

  # The scene is the badge, the gulls' one blank-free run of nothing of their own, and the room.
  def test_the_room_of_the_groups_is_counted_in_what_the_scene_uses
    screen = harbor_screen

    assert_equal BYTES + (4 * BYTES), screen.used
    assert_equal 0, screen.gaps
  end

  def test_a_grouped_sprite_says_its_pictures_come_by_groups
    gulls = harbor_screen.sprites.find { |entry| entry.sprite == :gull }
    rooms = harbor_screen.picture_groups.fetch(0)
    places = rooms.groups.flat_map(&:places).to_h

    assert_equal :by_groups, gulls.held
    assert gulls.rewritten?
    assert_equal [places.fetch(:art_3)], gulls.poses.to_h.fetch(:art_3), "a pose is drawn from its group's place"
  end

  # The gulls and the buoy keep nothing outside the room: neither has a run of its own, so neither
  # stands at the badge's tiles, and they share no run with each other either.
  def test_a_sprite_whose_pictures_all_come_by_groups_has_no_run_of_its_own
    screen = harbor_screen
    gulls, buoy, badge = %i[gull buoy badge].map { |name| screen.sprites.find { |entry| entry.sprite == name } }

    assert_equal [0, 0], [gulls.tiles, buoy.tiles]
    assert_operator gulls.first_tile, :>=, screen.picture_groups.fetch(0).first_tile
    refute_equal badge.first_tile, gulls.first_tile
    assert_empty gulls.shares_with
    assert_empty buoy.shares_with
  end

  def test_the_groups_are_in_the_data_form_and_the_printed_map
    rooms = harbor_screen.to_h.fetch(:picture_groups).first
    map = harbor.sprite_memory.to_s

    assert_equal :rooms, rooms[:name]
    assert_equal [1, 2], rooms.dig(:worst, :groups)
    assert_match(/by groups +gull/, map)
    assert_match(/picture_groups :rooms/, map)
    assert_match(/worst .*groups 1 and 2/, map)
    assert_match(/group 2 \(6144 bytes\): art_4 at tile \d+, art_5 at tile \d+, art_6/, map)
  end

  # Two rooms of ten pictures each, up together: 40K, more than the console holds. The build stops
  # and says which set of groups is the one that does not fit.
  def test_a_set_of_groups_too_big_to_be_up_together_is_named_when_the_build_stops
    art = TestPictureGroupsMemoryMap.method(:art)
    error = assert_raises(GBA::SpriteMemoryFull) do
      RubyGBA.build("CROWDED", out: StringIO.new, err: StringIO.new) do
        screen :tiled
        PICTURES.each_with_index { |name, n| image name, width: 64, height: 64, data: art.call(n) }
        rooms = picture_groups :rooms, { 0 => PICTURES[1..10], 1 => PICTURES[11..20] }, up_together: [[0, 1]]
        gulls = pool :gull, x: 0, y: 0, look: 0, capacity: 2, facing: PICTURES[1..20].to_h { |name| [name, name] }
        rooms.show 0, 1
        game_loop do
          rooms.show 0, 1
          gulls.each { |gull| gull.face PICTURES[1..20], showing: gull.look }
        end
      end
    end

    assert_match(/picture_groups :rooms/, error.message)
    assert_match(/groups 0 and 1/, error.message)
    assert_match(/:art_1 \(2048\)/, error.message)
    assert_match(/picture_groups :rooms/, error.sprite_memory.to_s)
  end

  # A GRID OF ROOMS (see ManyRoomsGame): every room's pictures come to several times what the
  # console holds, and the busiest set up together is two rooms across an edge. The rooms are
  # placed like a chessboard's squares, those of one colour sharing places, so the room the
  # groups take is the pair's and the scene is the pair with the hero and the heart.
  def test_the_busiest_set_of_many_rooms_is_two_rooms
    rom = RubyGBA.build("ROOMS", out: StringIO.new, err: StringIO.new) { ManyRoomsGame.declare(self) }
    play = rom.sprite_memory.screens.find { |screen| screen.scene == :play }
    rooms = play.picture_groups.fetch(0)
    pair = 2 * ManyRoomsGame::ROOM_BYTES

    assert_operator rooms.groups.sum(&:bytes), :>, CONSOLE_SPRITE_BYTES, "every room's pictures would not fit at once"
    assert_equal pair, rooms.worst.bytes
    assert_equal 2, rooms.worst.groups.length
    assert_equal pair, rooms.bytes
    assert_equal pair + ManyRoomsGame::EVERYWHERE_BYTES, play.used
  end

  private def full_scene_message(&block)
    art = TestPictureGroupsMemoryMap.method(:art)
    assert_raises(GBA::SpriteMemoryFull) do
      RubyGBA.build("CROWDED", out: StringIO.new, err: StringIO.new) do
        screen :tiled
        PICTURES.each_with_index { |name, n| image name, width: 64, height: 64, data: art.call(n) }
        var :state, 0
        instance_exec(&block)
        game_loop { case_var(:state) { when_val 0, :gallery } }
      end
    end.message
  end

  # The groups are every screen's, and a scene's pool shows them: they are what fills the scene.
  def test_groups_of_every_screen_are_named_when_a_scene_does_not_fit
    message = full_scene_message do
      rooms = picture_groups :rooms, { 0 => PICTURES[1..9], 1 => PICTURES[10..18] }, up_together: [[0, 1]]
      rooms.show 0, 1
      scene(:gallery) do
        gulls = pool :gull, x: 0, y: 0, look: 0, capacity: 2, facing: PICTURES[1..18].to_h { |name| [name, name] }
        gulls.each { |gull| gull.face PICTURES[1..18], showing: gull.look }
      end
    end

    assert_match(/picture_groups :rooms/, message)
  end

  # Statues fill the scene; the one small group is not what to make smaller, and is not named.
  def test_groups_are_not_named_when_they_are_not_what_fills_the_scene
    message = full_scene_message do
      scene(:gallery) do
        rooms = picture_groups :rooms, { 0 => %i[art_30] }
        rooms.show 0
        sprite :lamp, facing: { lit: :art_30 }, at: [0, 0]
        PICTURES[1..17].each_with_index { |name, n| sprite :"statue_#{n}", facing: { still: name }, at: [n * 8, 40] }
      end
    end

    refute_match(/picture_groups/, message)
    assert_match(/:art_1 \(2048\)/, message)
  end
end
