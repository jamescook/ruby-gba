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
  NAMES = (0...(ROOMS * PICTURES_A_ROOM)).map { |n| :"thing_#{n}" }.freeze
  # A 32x32 picture in the three colours a Color sprite holds, whose every 8x8 tile differs from
  # every other picture's — the Color keeps a tile two pictures share only once — from a run of
  # numbers that start at +number+.
  def self.art(number)
    seed = number + 1
    (0...32).map do |_|
      (0...32).map do
        seed = ((seed * 1_103_515_245) + 12_345) % (2**31)
        "rg#"[(seed >> 16) % 3]
      end.join
    end.join("\n")
  end

  # The rooms, the room the game is in moving on every PASSES_A_ROOM passes, and the room after it up
  # as well for the last pass of each. A thing of the room the game is in stands on the left; on the
  # last pass, one of the next room's stands on the right. With +grouped+ false the same game without
  # picture groups.
  private def rooms(grouped: true)
    names = NAMES
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      names.each_with_index do |name, n|
        image(name, "#" => :white, "r" => :red, "g" => :green) { TestGBCPictureGroups.art(n) }
      end
      groups = (0...ROOMS).to_h { |room| [room, names[room * PICTURES_A_ROOM, PICTURES_A_ROOM]] }
      together = (0...(ROOMS - 1)).map { |room| [room, room + 1] }
      shelf = picture_groups(:rooms, groups, up_together: together) if grouped
      passes = var :passes, 0
      here = var :here, 0
      beside = var :beside, 0
      left = sprite :left, facing: names.to_h { |name| [name, name] }, at: [16, 40]
      right = sprite :right, facing: names.to_h { |name| [name, name] }, at: [96, 40]
      right.hide
      shelf&.show here, beside
      game_loop do
        passes.add! 1
        here.set!((passes / PASSES_A_ROOM).clamp(0, ROOMS - 1))
        beside.set! here
        right.hide
        ((passes % PASSES_A_ROOM == PASSES_A_ROOM - 1) & (here < ROOMS - 1)).then do
          beside.set! here + 1
          right.show
        end
        shelf&.show here, beside
        left.face names, showing: (here * PICTURES_A_ROOM) + (passes % PICTURES_A_ROOM)
        right.face names, showing: (beside * PICTURES_A_ROOM) + 1
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_rooms_whose_pictures_pass_what_the_color_holds_play_as_the_interpreter_does
    player = game_player.run(rooms, frames: ROOMS * PASSES_A_ROOM)

    assert_equal ROOMS - 1, player[:here], "the walk reached the last room"
  end

  def test_the_same_pictures_without_groups_are_refused
    error = assert_raises(GBC::LoweringError) { GBC.new.build(rooms(grouped: false)) }

    assert_match(/need #{NAMES.length * 16} tiles of 8×8/, error.message)
    assert_match(/room for 256/, error.message)
  end
end
