# frozen_string_literal: true

require "test_helper"
require "differential"

# WHICH LISTS OF SPRITE COLOURS A ROOM USES. A game whose things between them wear more
# lists than the console has groups for sprites still fits, so long as no one room uses
# more at once: the game says which lists are in use as it enters a room, and the build
# works out the rest.
class TestColorsInUse < Minitest::Test
  include Differential

  OWN = [:transparent, :red, :green].freeze

  # An 8x8 thing, left half the first colour of its list and right half the second, so a
  # swapped colour shows at a known place.
  SHIP = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  # More lists than the console has groups for sprites, and how many each room uses.
  LISTS = 20
  PER_ROOM = 4

  # List number +n+: two colours no other list has.
  def self.colors_of_list(n) = [:transparent, VBlank::Graphics::Color.rgb(n, 31 - n, 5), VBlank::Graphics::Color.rgb(31 - n, n, 9)]

  # The thing's picture and the twenty lists, then whatever the block declares.
  private def built(&body)
    klass = self.class
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      (0...LISTS).each { |n| colors :"set#{n}", klass.colors_of_list(n) }
      instance_eval(&body)
    end
    builder.finalize_program
    builder.program
  end

  private def list_names = (0...LISTS).map { |n| :"set#{n}" }

  # The lists room +r+ uses: the next four.
  private def rooms = list_names.each_slice(PER_ROOM).to_a

  # THE SHAPE THIS IS FOR: a pool whose things are of many kinds, each kind drawn with a list
  # of its own, and a room holding things of a few kinds. Room 0 holds kinds 0 to 3, and from
  # the third pass the game is in room 1, which holds kinds 4 to 7.
  private def entering_next_room(say_which: true)
    names = list_names
    room_lists = rooms
    built do
      things = pool :thing, x: 0, y: 0, kind: 0, capacity: PER_ROOM, image: :ship
      PER_ROOM.times { |n| things.spawn x: 40 + (n * 20), y: 40, kind: n }
      room = var :room, 0
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == 3).then do
          room.set! 1
          things.each { |thing| thing.kind.add! PER_ROOM }
        end
        colors_in_use room_lists, showing: room if say_which
        things.each { |thing| thing.draw_with names, showing: thing.kind }
      end
    end
  end

  # The left half of each of the four things, as the interpreter draws them after +frames+.
  private def things_drawn(frames)
    i = game_player.run(entering_next_room, frames: frames)
    (0...PER_ROOM).map { |n| i.screen.pixel(41 + (n * 20), 41) }
  end

  # Saying which lists are in use is a hint the console no longer needs: without it, each list
  # borrows a group while a thing on screen wears it, and the picture is the same.
  def test_twenty_lists_without_saying_which_are_in_use_fit_too
    [3, 6].each { |frames| assert_backends_agree(entering_next_room(say_which: false), frames: frames) }
  end

  def test_each_thing_wears_its_own_list_in_the_room_that_uses_it
    # The second pass, still in the first room, as far behind as the framework draws
    # (Testing#framework_drawing_lag).
    assert_equal (0...4).map { |n| self.class.colors_of_list(n)[1] }, things_drawn(2 + framework_drawing_lag), "the first room"
    assert_equal (4...8).map { |n| self.class.colors_of_list(n)[1] }, things_drawn(6), "the second room"
  end

  def test_the_console_fits_twenty_lists_used_four_to_a_room
    [3, 4, 5, 6].each { |frames| assert_backends_agree(entering_next_room, frames: frames) }
  end

  # Until the game first says, the first set named is in use: the things of room 0 wear their
  # own lists from the first frame, though the game says so only from the fourth pass.
  def test_the_first_set_is_in_use_until_the_game_says
    names = list_names
    room_lists = rooms
    late = built do
      things = pool :thing, x: 0, y: 0, kind: 0, capacity: PER_ROOM, image: :ship
      PER_ROOM.times { |n| things.spawn x: 40 + (n * 20), y: 40, kind: n }
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass > 3).then { colors_in_use room_lists, showing: 0 }
        things.each { |thing| thing.draw_with names, showing: thing.kind }
      end
    end
    i = game_player.run(late, frames: 2)

    assert_equal (0...4).map { |n| self.class.colors_of_list(n)[1] }, (0...4).map { |n| i.screen.pixel(41 + (n * 20), 41) }
    assert_backends_agree(late, frames: 2)
  end

  # Sets that overlap in a ring — each list in use with both the others, but never all three
  # at once — still fit, in three groups rather than two.
  def test_sets_that_overlap_in_a_ring_fit
    ring = built do
      things = pool :thing, x: 0, y: 0, kind: 0, capacity: 2, image: :ship
      things.spawn x: 40, y: 40, kind: 0
      things.spawn x: 60, y: 40, kind: 1
      pass = var :pass, 0
      room = var :room, 0
      game_loop do
        pass.add! 1
        (pass == 3).then do
          room.set! 1
          things.each { |thing| thing.kind.add! 1 }
        end
        colors_in_use [%i[set0 set1], %i[set1 set2], %i[set2 set0]], showing: room
        things.each { |thing| thing.draw_with %i[set0 set1 set2], showing: thing.kind }
      end
    end
    i = game_player.run(ring, frames: 6)

    assert_equal [self.class.colors_of_list(1)[1], self.class.colors_of_list(2)[1]], [i.screen.pixel(41, 41), i.screen.pixel(61, 41)]
    [3, 6].each { |frames| assert_backends_agree(ring, frames: frames) }
  end

  # A thing left standing from another room is drawn in whatever its group holds now, on every
  # build — including the places past the end of a shorter list it takes turns with.
  def test_a_thing_left_from_another_room_looks_the_same_on_every_build
    stale = built do
      image :dot, width: 8, height: 8, data: Array.new(64, :blue), colors: %i[transparent blue]
      colors :short, %i[transparent white]
      ship = sprite :ship, at: [40, 40]
      dot = sprite :dot, at: [80, 40]
      room = var :room, 0
      game_loop do
        (ship.x < 100).then { ship.x.add! 1 }
        (ship.x > 42).then { room.set! 1 }
        ship.draw_with :set0
        dot.draw_with :short
        colors_in_use [[:set0], [:short]], showing: room
      end
    end

    [2, 6].each { |frames| assert_backends_agree(stale, frames: frames) }
  end

  # --- scenes ---

  # Two scenes each say which of their own lists are in use, and a third uses every one of
  # the sixteen groups on lists of its own. The groups the first two scenes' sets take are
  # theirs while they are up, as any scene's are, so the third still fits.
  private def three_scenes
    klass = self.class
    built do
      (LISTS...(LISTS + 3)).each { |n| colors :"set#{n}", klass.colors_of_list(n) }
      { one: (0...4), two: (4...8) }.each do |name, kinds|
        scene(name) do
          lists = kinds.map { |n| :"set#{n}" }
          ship = sprite :ship, at: [40, 40]
          colors_in_use lists.each_slice(2).to_a, showing: 0
          ship.draw_with lists, showing: 0
        end
      end
      scene(:three) do
        lists = (8...(LISTS + 3)).map { |n| :"set#{n}" }
        ship = sprite :ship, at: [40, 40]
        ship.draw_with lists, showing: lists.length - 1
      end
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick > 3).then { state.set! 1 }
        (tick > 6).then { state.set! 2 }
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
          when_val 2, :three
        end
      end
    end
  end

  def test_each_scenes_sets_take_groups_only_while_it_is_up
    [3, 6, 9].each { |frames| assert_backends_agree(three_scenes, frames: frames) }
  end

  # --- the count that fails is one room's ---

  # Seventeen kinds in one room, each with a list of its own, plus the thing's own colours.
  private def one_room_too_many
    names = list_names.first(17)
    built do
      things = pool :thing, x: 0, y: 0, kind: 0, capacity: 2, image: :ship
      things.spawn x: 40, y: 40, kind: 0
      game_loop do
        colors_in_use [names.first(4), names], showing: 1
        things.each { |thing| thing.draw_with names, showing: thing.kind }
      end
    end
  end

  def test_a_room_that_does_not_fit_is_named_by_its_line
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(one_room_too_many) }

    assert_match(/16 groups/, error.message)
    assert_match(/biggest is set 1 of the sets at test_colors_in_use\.rb:\d+/, error.message)
    assert_match(/It names :set0, :set1, .*:set16\./, error.message)
  end

  # --- friendly errors ---

  private def refused(&body) = assert_raises(ArgumentError) { built(&body) }.message

  def test_naming_something_that_is_not_a_list_says_so
    message = refused do
      ship = sprite :ship, at: [40, 40]
      ship.draw_with %i[set0 set1], showing: 0
      colors_in_use %i[set0 ghost]
    end

    assert_match(/:ghost, which is not a list of colors/, message)
  end

  def test_several_sets_and_nothing_to_pick_between_them_says_so
    message = refused do
      ship = sprite :ship, at: [40, 40]
      ship.draw_with %i[set0 set1], showing: 0
      colors_in_use [[:set0], [:set1]]
    end

    assert_match(/nothing to pick between them/, message)
  end

  def test_one_set_and_showing_says_so
    message = refused do
      ship = sprite :ship, at: [40, 40]
      ship.draw_with %i[set0 set1], showing: 0
      colors_in_use %i[set0 set1], showing: 0
    end

    assert_match(/give it a list of sets/, message)
  end

  def test_a_list_no_sprite_draws_with_says_so
    message = refused do
      ship = sprite :ship, at: [40, 40]
      ship.draw_with %i[set0 set1], showing: 0
      colors_in_use %i[set0 set5]
    end

    assert_match(/:set5, but no sprite or pool draws with it/, message)
  end

  def test_a_list_that_is_also_recolored_says_so
    message = refused do
      ship = sprite :ship, at: [40, 40]
      ship.draw_with %i[set0 set1], showing: 0
      recolor :set1, :set2
      colors_in_use %i[set0 set1]
    end

    assert_match(/:set1 was told to hold other colors with `recolor`/, message)
  end
end
