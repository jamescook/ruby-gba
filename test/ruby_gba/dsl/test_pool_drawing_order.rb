# frozen_string_literal: true

require "test_helper"
require "differential"

# WHICH OF TWO OVERLAPPING THINGS IN ONE POOL IS IN FRONT: the one spawned first. That is
# the order a walk goes in too, and like the walk it does not depend on which slot a thing
# landed in — a slot freed and taken again says nothing about when its thing came.
#
# Every test spawns 8x8 squares that overlap by half and reads the pixel where they both
# lie, on the interpreter and on the console. A thing's colour is its `tag` field, so a test
# says which thing is which without knowing a slot.
class TestPoolDrawingOrder < Minitest::Test
  runs_on :reference, :native

  include Differential

  COLORS = %i[red green blue].freeze
  SQUARE = ("########\n" * 8).freeze

  # A tiled game with a pool of coloured squares. The block is the game loop's body, handed
  # the pool and a counter of the passes so far; after it, every live thing takes the colour
  # its tag names.
  private def crowd_program(capacity: 3, on_full: :drop, &script)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      COLORS.each { |color| image(:"#{color}_square", "#" => color) { SQUARE } }
      crowd = pool :crowd, x: 0, y: 0, tag: 0, capacity: capacity, on_full: on_full,
                           facing: COLORS.to_h { |color| [color, :"#{color}_square"] }
      step = var :step, 0
      game_loop do
        instance_exec(crowd, step, &script)
        crowd.each { |thing| thing.face COLORS, showing: thing.tag }
        step.add! 1
      end
    end
    b.finalize_program
    b.program
  end

  # [interpreter, console]: the colour name at (x, y) once the script has played out.
  private def colors_at(prog, x, y)
    rom = ROM.assemble(GBA.new.lower(prog), title: "PDRW")
    v = assert_emulator_loads_rom(rom, frames: 14)
    seen = game_player.run(prog, frames: 12).screen.pixel(x, y)
    [COLORS.find { |color| Color.resolve(color) == seen } || seen,
     COLORS.find { |color| v.pixel_is?(x, y, color) } || v.pixel_gba(x, y)]
  end

  RED = 0
  GREEN = 1
  BLUE = 2

  def test_the_first_spawned_is_in_front
    prog = crowd_program do |crowd, step|
      (step == 0).then do
        crowd.spawn x: 40, y: 40, tag: RED
        crowd.spawn x: 44, y: 44, tag: GREEN
      end
    end

    assert_equal %i[red red], colors_at(prog, 45, 45), "where both lie, the older one shows"
    assert_equal %i[green green], colors_at(prog, 50, 50), "and the newer one is drawn behind it"
  end

  # The slot a removed thing gave back is the next one handed out, so the thing spawned last
  # lands in the slot the very first thing had.
  def test_a_thing_spawned_into_a_freed_slot_is_still_behind_an_older_one
    prog = crowd_program do |crowd, step|
      (step == 0).then do
        crowd.spawn x: 200, y: 100, tag: BLUE
        crowd.spawn x: 40, y: 40, tag: RED
      end
      (step == 1).then { crowd.each { |thing| (thing.tag == BLUE).then { thing.remove } } }
      (step == 2).then { crowd.spawn x: 44, y: 44, tag: GREEN }
    end

    assert_equal %i[red red], colors_at(prog, 45, 45), "the older one is in front, whatever slot the newer took"
    assert_equal %i[green green], colors_at(prog, 50, 50)
  end

  # Three deep, after the slots have been shuffled: each is in front of every one spawned
  # after it.
  def test_three_overlapping_things_stack_oldest_in_front
    prog = crowd_program(capacity: 4) do |crowd, step|
      (step == 0).then do
        crowd.spawn x: 200, y: 100, tag: BLUE
        crowd.spawn x: 200, y: 120, tag: BLUE
        crowd.spawn x: 40, y: 40, tag: GREEN
      end
      (step == 1).then { crowd.each { |thing| (thing.x == 200).then { thing.remove } } }
      (step == 2).then do
        crowd.spawn x: 42, y: 42, tag: RED
        crowd.spawn x: 44, y: 44, tag: BLUE
      end
    end

    assert_equal %i[green green], colors_at(prog, 45, 45), "all three lie here: the oldest shows"
    assert_equal %i[red red], colors_at(prog, 49, 49), "past the oldest, the second shows over the third"
    assert_equal %i[blue blue], colors_at(prog, 51, 51), "and the newest shows only where it lies alone"
  end

  # A full pool that reuses its oldest thing makes it the newest, so it goes behind.
  def test_a_recycled_thing_goes_behind_the_ones_that_were_already_there
    prog = crowd_program(capacity: 2, on_full: :recycle_oldest) do |crowd, step|
      (step == 0).then do
        crowd.spawn x: 200, y: 100, tag: BLUE
        crowd.spawn x: 40, y: 40, tag: RED
      end
      (step == 2).then { crowd.spawn x: 44, y: 44, tag: GREEN }
    end

    assert_equal %i[red red], colors_at(prog, 45, 45)
    assert_equal %i[green green], colors_at(prog, 50, 50)
  end

  # Removing the thing in front shows the one behind it, where it was.
  def test_removing_the_front_one_shows_the_one_behind
    prog = crowd_program do |crowd, step|
      (step == 0).then do
        crowd.spawn x: 40, y: 40, tag: RED
        crowd.spawn x: 44, y: 44, tag: GREEN
      end
      (step == 2).then { crowd.each { |thing| (thing.tag == RED).then { thing.remove } } }
    end

    assert_equal %i[green green], colors_at(prog, 45, 45)
    assert_equal [0, 0], colors_at(prog, 41, 41), "nothing is left where only the removed one was"
  end

  # --- what moves with a thing when its place in the order does ---

  OWN = %i[transparent red green].freeze
  HURT = %i[transparent yellow white].freeze

  # Two ships; the newer is told to draw with other colours, and then the older one leaves,
  # so the newer moves up to the front place.
  private def recolored_program
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: Array.new(64, :red), colors: OWN
      colors :hurt, HURT
      ships = pool :ship, x: 0, y: 0, capacity: 2, image: :ship
      step = var :step, 0
      game_loop do
        (step == 0).then do
          ships.spawn x: 40, y: 40
          ships.spawn x: 80, y: 40
        end
        ships.each do |ship|
          (ship.x == 80).then { ship.draw_with :hurt }
          ((step == 2) & (ship.x == 40)).then { ship.remove }
        end
        step.add! 1
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_thing_keeps_its_colors_when_an_older_one_leaves
    i = game_player.run(recolored_program, frames: 6)

    assert_equal Color.resolve(:yellow), i.screen.pixel(81, 41), "the hurt ship is still the hurt one"
    assert_equal 0, i.screen.pixel(41, 41), "and the ship that left is gone"
    assert_backends_agree(recolored_program, frames: 2)
    assert_backends_agree(recolored_program, frames: 6)
  end

  # A thing moved by a `once_a_frame` body is moved in the gap before the frame is drawn, so
  # the picture shows where it is now and not where it was a frame ago.
  def test_a_thing_moved_between_frames_is_drawn_where_it_now_is
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:red_square, "#" => :red) { SQUARE }
      crowd = pool :crowd, x: 0, y: 0, capacity: 2, image: :red_square
      crowd.spawn x: 10, y: 40
      once_a_frame { crowd.each { |thing| thing.x.add! 3 } }
      game_loop {}
    end
    b.finalize_program
    i = game_player.run(b.program, frames: 5)

    assert_equal i.pool(:crowd, :x).compact, i.sprites(:crowd).map(&:x)
    assert_backends_agree(b.program, frames: 5)
  end
end
