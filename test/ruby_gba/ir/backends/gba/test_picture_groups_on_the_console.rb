# frozen_string_literal: true

require "test_helper"
require "differential"

# A SCENE'S PICTURES IN GROUPS, ON THE CONSOLE: only the groups up are in sprite memory.
#
# Each grouped picture has one place there, shared with pictures whose groups are never up with
# its own, and it is copied in between frames as one of its groups comes up. So the pictures have
# to be right on the very frame a sprite first shows them: after a change of room, while two
# rooms are up as the screen slides, and back in a scene after another scene's pictures went
# into the same memory. And a scene whose rooms would not all fit at once builds, since only the
# rooms up at once have to.
class TestPictureGroupsOnTheConsole < Minitest::Test
  include Differential

  # Fifteen colours, so every picture is stored the small way (half a byte a pixel).
  INKS = (1..15).map { |i| RubyGBA::Graphics::Color.rgb(i * 2, 31 - (i * 2), 10) }.freeze

  # A 64x64 picture filling its square and differing from every other: a slanted stripe pattern
  # shifted by the picture's number, with the number written along the top row.
  def big_art(number)
    (0...64).flat_map do |y|
      (0...64).map do |x|
        next INKS[(number >> (x % 8)) & 1] if y.zero?

        INKS[((x * 5) + (y * 3) + number) % 15]
      end
    end
  end

  # A program built through the DSL; the block is handed this test, for its pictures.
  private def program(&block)
    b = Builder.new
    b.instance_exec(self, &block)
    b.finalize_program
    b.program
  end

  # FOUR ROOMS IN A ROW, a picture each, walked through a room every four passes, with the next
  # one up beside it for the two passes before the screen gets there. One sprite shows the room
  # the game is in and the other the room beside, and the hero shows in every room.
  private def walk_through_four_rooms
    program do |t|
      screen :tiled
      rooms = (0...4).map { |n| :"room_#{n}" }
      rooms.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(n) }
      image :hero, width: 64, height: 64, data: t.big_art(50)
      passes = var :passes, 0
      here = var :here, 0
      beside = var :beside, 0
      up = picture_groups :rooms, rooms.each_with_index.to_h { |name, n| [n, [name]] },
                          up_together: [[0, 1], [1, 2], [2, 3]]
      this_room = sprite :this_room, facing: rooms.to_h { |name| [name, name] }, at: [8, 8]
      next_room = sprite :next_room, facing: rooms.to_h { |name| [name, name] }, at: [88, 8]
      sprite :hero, facing: { hero: :hero }, at: [168, 8]
      show = lambda do
        up.show here, beside
        this_room.face rooms, showing: here
        next_room.face rooms, showing: beside
      end
      show.call
      game_loop do
        passes.add! 1
        here.set!((passes / 4).clamp(0, 3))
        beside.set!(((passes + 2) / 4).clamp(0, 3))
        show.call
      end
    end
  end

  def test_each_room_shows_right_on_the_frame_it_comes_up
    prog = walk_through_four_rooms
    (2..15).each { |frames| assert_backends_agree(prog, frames: frames, name: "ROOMS") }
  end

  # FORTY ROOMS, a 64x64 picture each: two kilobytes a room, eighty for all forty, which is more
  # than the console's sprite memory holds. A pool of twenty things can show any room's picture,
  # so keeping each thing to one frame at a time would not fit either: forty kilobytes. One room
  # is up at a time, so the scene needs one room's room. The game opens on another scene, whose
  # pictures fill the same memory, and goes back to it and comes back, so the scene's rooms have
  # to come up again after it.
  ROOM_COUNT = 40

  private def maze_of_forty_rooms
    program do |t|
      screen :tiled
      rooms = (0...ROOM_COUNT).map { |n| :"cell_#{n}" }
      rooms.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(n) }
      banners = (0...8).map { |n| :"banner_#{n}" }
      banners.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(100 + n) }
      state = var :state, 1
      tick = var :tick, 0
      scene(:maze) do
        up = picture_groups :cells, rooms.each_with_index.to_h { |name, n| [n, [name]] }
        things = pool :thing, x: 0, y: 0, capacity: 20, facing: rooms.to_h { |name| [name, name] }
        (things.count == 0).then do
          things.spawn(x: 8, y: 8)
          things.spawn(x: 88, y: 40)
        end
        room = (tick * 7) % ROOM_COUNT
        up.show room
        things.each { |thing| thing.face rooms, showing: room }
      end
      scene(:away) { sprite :banner, at: [8, 8], frames: banners, rate: 60 }
      game_loop do
        tick.add! 1
        (tick == 3).then { state.set! 0 }
        (tick == 8).then { state.set! 1 }
        (tick == 10).then { state.set! 0 }
        case_var(:state) { when_val 0, :maze; when_val 1, :away }
      end
    end
  end

  # GROUPS OF EVERY SCREEN, KEPT ACROSS A CHANGE OF SCENE. The game says which room is up from
  # its own loop, outside any scene, so the groups are the game's and stay up while another
  # scene's pictures fill the memory above them; coming back, nothing has to be copied again. The
  # walker shows its room's picture both ways round, the turned one drawn from the same tiles.
  private def walker_between_scenes
    program do |t|
      screen :tiled
      image :room_0, width: 64, height: 64, data: t.big_art(0)
      image :room_1, width: 64, height: 64, data: t.big_art(1)
      banners = (0...8).map { |n| :"banner_#{n}" }
      banners.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(100 + n) }
      state = var :state, 0
      tick = var :tick, 0
      here = var :here, 0
      look = var :look, 0
      up = picture_groups :rooms, { 0 => %i[room_0], 1 => %i[room_1] }
      scene(:walking) do
        walker = sprite :walker, facing: { ahead: :room_0, back: mirror(:room_0), other: :room_1 }, at: [8, 8]
        walker.face %i[ahead back other], showing: look
      end
      scene(:away) { sprite :banner, at: [8, 8], frames: banners, rate: 60 }
      up.show here
      game_loop do
        tick.add! 1
        here.set!((tick / 6) % 2)
        look.set! here * 2
        (here == 0).then { look.set! tick % 2 }
        up.show here
        (tick == 3).then { state.set! 1 }
        (tick == 5).then { state.set! 0 }
        case_var(:state) { when_val 0, :walking; when_val 1, :away }
      end
    end
  end

  # A SCENE THAT LOADS FIRST, GIVEN THE SCREEN BACK. Its room is up as it leaves, and the scene
  # away fills sprite memory with pictures of its own. Back again, none of the harbor's code runs
  # on the pass it takes over on, and its things are drawn after that pass showing the room they
  # showed as it was left: its pictures have to be back in their places by then.
  private def harbor_given_back
    program do |t|
      screen :tiled
      rooms = (0...2).map { |n| :"dock_#{n}" }
      rooms.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(n) }
      banners = (0...8).map { |n| :"banner_#{n}" }
      banners.each_with_index { |name, n| image name, width: 64, height: 64, data: t.big_art(100 + n) }
      state = var :state, 0
      tick = var :tick, 0
      scene(:harbor, loads_first: true) do
        up = picture_groups :docks, rooms.each_with_index.to_h { |name, n| [n, [name]] }
        boats = pool :boat, x: 0, y: 0, capacity: 4, facing: rooms.to_h { |name| [name, name] }
        (boats.count == 0).then do
          boats.spawn(x: 8, y: 8)
          boats.spawn(x: 88, y: 40)
        end
        up.show 1
        boats.each { |boat| boat.face rooms, showing: 1 }
      end
      scene(:away) { sprite :banner, at: [8, 8], frames: banners, rate: 60 }
      game_loop do
        tick.add! 1
        (tick == 3).then { state.set! 1 }
        (tick == 6).then { state.set! 0 }
        case_var(:state) { when_val 0, :harbor; when_val 1, :away }
      end
    end
  end

  # Frames 3 and 6 are the frames each scene takes over on, where the scene leaving still has
  # its sprites up over pictures the next one is copying in. Frame 7 is the first the harbor's
  # boats are drawn again.
  def test_a_scene_that_loads_first_shows_its_rooms_on_the_pass_it_is_given_back
    prog = harbor_given_back
    [2, 4, 5, 7, 8, 10].each { |frames| assert_backends_agree(prog, frames: frames, name: "HARBOR") }
  end

  def test_groups_of_every_screen_stay_up_across_a_change_of_scene
    prog = walker_between_scenes
    [2, 4, 6, 7, 8, 13].each { |frames| assert_backends_agree(prog, frames: frames, name: "WALKER") }
  end

  def test_a_scene_whose_rooms_would_not_all_fit_builds_and_plays
    prog = maze_of_forty_rooms
    [5, 7, 12, 13].each { |frames| assert_backends_agree(prog, frames: frames, name: "MAZE") }
  end
end
