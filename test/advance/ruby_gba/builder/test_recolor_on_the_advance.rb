# frozen_string_literal: true

require "test_helper"
require "differential"

# THE TESTS OF ruby_gba/builder/test_recolor.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# A LIST OF SPRITE COLOURS THAT HOLDS OTHER COLOURS while the game runs. A sprite told to
# draw with a list is drawn in whatever that list holds now, so one list can dress a
# goblin in one room and a bat in the next: the list is a slot, and `recolor` says what
# is in it.
class TestRecolorOnTheAdvance < Minitest::Test
  include Differential

  OWN = [:transparent, :red, :green].freeze
  SLOT = [:transparent, :blue, :white].freeze
  WARM = [:transparent, :yellow, :orange].freeze
  COLD = [:transparent, :gray, :black].freeze

  # An 8x8 ship, left half the first colour of its list and right half the second, so a
  # swapped colour shows at a known place.
  SHIP = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  # More sets of colours than the console has groups for sprites.
  SETS = 20

  # Set number +n+: two colours no other set has.
  def self.set(n) = [:transparent, RubyGBA::Graphics::Color.rgb(n, 31 - n, 5), RubyGBA::Graphics::Color.rgb(31 - n, n, 9)]

  # The ship's picture and the lists, then whatever the block declares.
  private def built(&body)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      colors :slot, SLOT
      colors :warm, WARM
      colors :cold, COLD
      instance_eval(&body)
    end
    builder.finalize_program
    builder.program
  end

  # A ship drawn with the list :slot, and a loop that does what the block says. +before+
  # runs once, above the loop.
  private def program(before: nil, &game)
    built do
      ship = sprite :ship, at: [40, 40]
      ship.draw_with :slot
      instance_exec(&before) if before
      game_loop { instance_exec(ship, &game) }
    end
  end

  # The ship's two halves, as the interpreter draws them after +frames+.
  private def halves(program, frames: 3)
    i = game_player.run(program, frames: frames)
    [i.screen.pixel(41, 41), i.screen.pixel(45, 41)]
  end

  private def colors_of(*names) = names.map { |name| Color.resolve(name) }

  # One of several, by a number the game works out: the ship's column counts up, so the
  # number is 2 by the third frame.
  private def counting_through_the_sets
    program do |ship|
      ship.x.add! 1
      recolor :slot, [:slot, :warm, :cold], showing: ship.x - 40
    end
  end

  # --- the console ---

  # --- the point of it: one group of sprite colors, however many sets ---

  # A ship that walks through twenty sets of colors, a new one each frame: by recoloring the
  # one list it is drawn with, or else by being told to draw with each of the twenty.
  private def many_sets(through_one_list:)
    klass = self.class
    built do
      names = (0...SETS).map { |n| colors :"set#{n}", klass.set(n) }
      ship = sprite :ship, at: [40, 40]
      ship.draw_with :slot if through_one_list
      game_loop do
        ship.x.add! 1
        if through_one_list
          recolor :slot, names, showing: ship.x - 41
        else
          ship.draw_with names, showing: ship.x - 41
        end
      end
    end
  end

  def test_twenty_sets_through_one_list_take_one_group
    walking = many_sets(through_one_list: true)
    # A sprite is drawn in the gap before the next frame, so the picture after thirteen
    # frames is where the twelfth pass put the ship, in the set that pass named.
    i = game_player.run(walking, frames: 13)

    assert_equal self.class.set(11).drop(1), [i.screen.pixel(53, 41), i.screen.pixel(57, 41)], "set 11"
    [3, 13, 22].each { |frames| assert_backends_agree(walking, frames: frames) }
  end

  # --- with a tint or a fade in force ---

  # --- pools ---

  private def guards_drawn_with_the_list
    built do
      guards = pool :guard, x: 0, y: 0, capacity: 4, image: :ship
      guards.spawn x: 40, y: 40
      guards.spawn x: 80, y: 40
      game_loop do
        guards.each { |g| g.draw_with :slot }
        recolor :slot, :warm
      end
    end
  end

  # THE SHAPE THIS IS FOR: a room's things stand on one pool, each drawn with one of a few
  # lists that are slots, and walking into the next room fills every slot from that room's
  # row of sets on the same frame. Four slots declared alike, so each has to have a group of
  # its own; room 0 wears sets 0 to 3 and room 1, from the third pass, sets 4 to 7.
  private def room_of_things
    klass = self.class
    built do
      sets = (0...SETS).map { |n| colors :"set#{n}", klass.set(n) }
      slots = (0...4).map { |n| colors :"slot#{n}", SLOT }
      things = pool :thing, x: 0, y: 0, slot: 0, capacity: 4, image: :ship
      4.times { |n| things.spawn x: 40 + (n * 20), y: 40, slot: n }
      room = var :room, 0
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == 3).then { room.set! 1 }
        things.each { |thing| thing.draw_with slots, showing: thing.slot }
        slots.each_with_index { |slot, n| recolor slot, sets, showing: (room * 4) + n }
      end
    end
  end

  # The left half of each of the four things, as the interpreter draws them after +frames+.
  private def things_drawn(frames)
    i = game_player.run(room_of_things, frames: frames)
    (0...4).map { |n| i.screen.pixel(41 + (n * 20), 41) }
  end

  def test_a_rooms_things_wear_the_sets_their_slots_were_filled_with
    assert_equal (0...4).map { |n| self.class.set(n)[1] }, things_drawn(3), "the first room"
    assert_equal (4...8).map { |n| self.class.set(n)[1] }, things_drawn(6), "the second room"
    [3, 4, 5, 6].each { |frames| assert_backends_agree(room_of_things, frames: frames) }
  end

  # --- friendly errors ---

  private def refused(&body) = assert_raises(ArgumentError) { built(&body) }.message

end
