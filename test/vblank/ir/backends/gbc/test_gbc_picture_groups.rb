# frozen_string_literal: true

require "test_helper"

# PICTURES GROUPED BY ROOM ON THE COLOR, which draws its sprites from 256 tiles. A game of six
# rooms in a row, each with three pictures of 32x32 of its own — 48 tiles a room, 288 in all — fits,
# since a room is up only beside the next one along: the next room is up as well for the passes the
# screen moves to it. A room's 48 tiles are more than one blank copies, so each room coming up takes
# two blanks, the frame waiting for the second (Runtime::PictureGroups); test_picture_groups.rb plays
# the rest on every lowering.
class TestGBCPictureGroups < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  ROOMS = 6
  PICTURES_A_ROOM = 3
  PASSES_A_ROOM = 4
  # Twenty rooms of three: sixty pictures of 32x32, which the Color's part of the cartridge always
  # in view could not hold the pieces and outlines of when they were kept there.
  MANY_ROOMS = 20

  # The pictures of +count+ rooms, by name.
  def self.names(count) = (0...(count * PICTURES_A_ROOM)).map { |n| :"thing_#{n}" }

  # A 32x32 picture in the three colours a Color sprite holds and see-through pixels between them,
  # so two pictures touch only where both draw. Its every 8x8 tile differs from every other
  # picture's — the Color keeps a tile two pictures share only once — from a run of numbers that
  # start at +number+.
  def self.art(number)
    seed = number + 1
    (0...32).map do |_|
      (0...32).map do
        seed = ((seed * 1_103_515_245) + 12_345) % (2**31)
        "rg#."[(seed >> 16) % 4]
      end.join
    end.join("\n")
  end

  # The rooms, +count+ of them, the room the game is in moving on every PASSES_A_ROOM passes, and the
  # room after it up as well for the last pass of each. A thing of the room the game is in stands on
  # the left; on the last pass, one of the next room's stands on the right, over the left one's edge,
  # and whether the two touch is asked by their pixels. With +grouped+ false the same game without
  # picture groups.
  private def rooms(grouped: true, count: ROOMS)
    names = TestGBCPictureGroups.names(count)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      names.each_with_index do |name, n|
        image(name, "#" => :white, "r" => :red, "g" => :green, "." => :transparent) { TestGBCPictureGroups.art(n) }
      end
      groups = (0...count).to_h { |room| [room, names[room * PICTURES_A_ROOM, PICTURES_A_ROOM]] }
      together = (0...(count - 1)).map { |room| [room, room + 1] }
      shelf = picture_groups(:rooms, groups, up_together: together) if grouped
      passes = var :passes, 0
      here = var :here, 0
      beside = var :beside, 0
      touching = var :touching, 0
      left = sprite :left, facing: names.to_h { |name| [name, name] }, at: [16, 40]
      right = sprite :right, facing: names.to_h { |name| [name, name] }, at: [40, 40]
      right.hide
      shelf&.show here, beside
      game_loop do
        passes.add! 1
        here.set!((passes / PASSES_A_ROOM).clamp(0, count - 1))
        beside.set! here
        right.hide
        right.x.set! 96
        ((passes % PASSES_A_ROOM == PASSES_A_ROOM - 1) & (here < count - 1)).then do
          beside.set! here + 1
          right.show
          right.x.set! 40
        end
        shelf&.show here, beside
        left.face names, showing: (here * PICTURES_A_ROOM) + (passes % PICTURES_A_ROOM)
        right.face names, showing: (beside * PICTURES_A_ROOM) + 1
        touching.set! 0
        left.overlaps?(right).then { touching.add! 1 }
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_rooms_whose_pictures_pass_what_the_color_holds_play_as_the_interpreter_does
    player = game_player.run(rooms, frames: ROOMS * PASSES_A_ROOM)

    assert_equal ROOMS - 1, player[:here], "the walk reached the last room"
  end

  def test_sixty_grouped_pictures_build_and_play_as_the_interpreter_does
    player = game_player.run(rooms(count: MANY_ROOMS), frames: MANY_ROOMS * PASSES_A_ROOM)

    assert_equal MANY_ROOMS - 1, player[:here], "the walk reached the last room"
  end

  # The two things touch, by their pixels, on the pass the next room's stands over the left one's
  # edge, and not on the pass after, when it has gone back off to the right.
  def test_the_two_things_touch_while_both_are_up
    touching = [PASSES_A_ROOM - 1, PASSES_A_ROOM].map do |frames|
      game_player.run(rooms(count: MANY_ROOMS), frames: frames)[:touching]
    end

    assert_equal [1, 0], touching
  end

  # The pass two rooms' games change on: the pictures the sprites show, and the group up.
  CHANGE_PASS = 3

  # Two rooms of three pictures, the first room's group up from power-on and, from CHANGE_PASS,
  # group +then_up+ (5 names neither). Each of +sprites+ — its name, then [its pictures, the pose it
  # shows from CHANGE_PASS] — shows its first picture until then; a sprite of one picture shows it
  # all along, a pose the program never changes. With +shared+, the second room's first picture is
  # in the first room's group too.
  private def two_rooms(sprites:, then_up: 0, shared: false)
    names = TestGBCPictureGroups.names(2)
    first = names[0, PICTURES_A_ROOM] + (shared ? [names[PICTURES_A_ROOM]] : [])
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      names.each_with_index do |name, n|
        image(name, "#" => :white, "r" => :red, "g" => :green, "." => :transparent) { TestGBCPictureGroups.art(n) }
      end
      shelf = picture_groups(:rooms, { 0 => first, 1 => names[PICTURES_A_ROOM, PICTURES_A_ROOM] })
      passes = var :passes, 0
      things = sprites.map do |name, (pictures, later)|
        [sprite(name, facing: pictures.to_h { |picture| [picture, picture] }, at: [16, 40]), pictures, later,
         var(:"#{name}_pose", 0)]
      end
      shelf.show 0
      game_loop do
        passes.add! 1
        (passes >= CHANGE_PASS).then { shelf.show then_up }
        things.each do |thing, pictures, later, pose|
          next if pictures.length == 1

          (passes >= CHANGE_PASS).then { pose.set! later }
          thing.face pictures, showing: pose
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  # On the console the sprite would show whatever the room up put in sprite memory, so the
  # cartridge stops the game, in the interpreter's words. Played on the cartridge alone, since a
  # checked run's interpreter stops first.
  private def assert_stops_as_the_interpreter_does(program)
    said = assert_raises(VBlank::IR::ProgramError) { Reference.new.run(program, frames: CHANGE_PASS + 3) }
    stopped = assert_raises(VBlank::IR::ProgramError) { GBC::HeadlessRun.new.run(program, frames: CHANGE_PASS + 3) }

    assert_equal said.message, stopped.message
  end

  # A sprite whose one picture is the second room's: not up from power-on.
  def test_a_picture_the_program_never_changes_stops_the_cartridge_as_the_interpreter_does
    names = TestGBCPictureGroups.names(2)
    assert_stops_as_the_interpreter_does(two_rooms(sprites: { thing: [[names[PICTURES_A_ROOM + 1]], nil] }))
  end

  # The first room's picture is up until the sprite shows one of the second's.
  def test_a_picture_chosen_as_the_game_runs_stops_the_cartridge_once_it_is_not_up
    game = two_rooms(sprites: { thing: [TestGBCPictureGroups.names(2), PICTURES_A_ROOM + 1] })

    GBC::HeadlessRun.new.run(game, frames: CHANGE_PASS - 1)
    assert_stops_as_the_interpreter_does(game)
  end

  # The shared picture is in both groups, and from CHANGE_PASS the game says a number naming neither.
  def test_a_picture_in_two_groups_neither_up_stops_the_cartridge_as_the_interpreter_does
    game = two_rooms(sprites: { thing: [TestGBCPictureGroups.names(2), PICTURES_A_ROOM] }, then_up: 5, shared: true)

    GBC::HeadlessRun.new.run(game, frames: CHANGE_PASS - 1)
    assert_stops_as_the_interpreter_does(game)
  end

  # Two sprites showing pictures not up: the cartridge names the one the interpreter names.
  def test_of_two_sprites_not_up_the_cartridge_names_the_interpreters
    names = TestGBCPictureGroups.names(2)
    assert_stops_as_the_interpreter_does(two_rooms(sprites: { back: [names, PICTURES_A_ROOM + 1],
                                                              front: [names, PICTURES_A_ROOM + 2] }))
  end

  def test_the_same_pictures_without_groups_are_refused
    error = assert_raises(GBC::LoweringError) { GBC.new.build(rooms(grouped: false)) }

    assert_match(/need #{TestGBCPictureGroups.names(ROOMS).length * 16} tiles of 8×8/, error.message)
    assert_match(/room for 256/, error.message)
  end
end
