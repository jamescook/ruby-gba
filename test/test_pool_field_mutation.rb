# frozen_string_literal: true

require "test_helper"
require "differential"

# Changing ONE field of ONE pool instance. `each` hands back a row whose fields are
# mutable handles, so an instance moves by writing to its own slot in that field's
# backing list — `b.y.add b.vy` is really `y[i] = y[i] + vy[i]`, at an index the game
# works out as it runs.
#
# Two implementations sit behind those verbs. `set`/`add`/`sub` write a single
# expression straight back into the slot. `approach`/`abs`/`negate_abs`/`flip`/`clamp`
# have no single expression, so they round-trip through a scratch variable: load the
# slot, apply the ordinary mutator to that, store it back. Every test here reads the
# field's VALUE rather than a picture, because a field can hold a negative number and a
# coordinate cannot — and the console lowering is pinned at the bottom, where positions
# are what a marker's pixels reveal.
class TestPoolFieldMutation < Minitest::Test
  include Differential

  # Two instances start out holding the same number; +mutate+ is applied to the first
  # only. Both come back. The untouched one is half the point: a row writes at an index
  # the game works out, so changing a neighbour by mistake is the failure this shape has.
  def mutating(start, &mutate)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      var :changed, 0
      var :untouched, 0
      rows = pool :row, v: 0, tag: 0, capacity: 4
      rows.spawn v: start, tag: 1
      rows.spawn v: start, tag: 2
      rows.each do |row|
        (row.tag == 1).then { mutate.call(row.v) }
        (row.tag == 1).then { set :changed, row.v }
        (row.tag == 2).then { set :untouched, row.v }
      end
      halt
    end
    b.emit_pending_functions
    i = Reference.new.run(b.program)
    [i[:changed], i[:untouched]]
  end

  # --- the mutators that write one expression back into the slot ---

  def test_set_replaces_the_rows_own_value
    changed, untouched = mutating(50) { |v| v.set 100 }

    assert_equal 100, changed
    assert_equal 50, untouched, "the other live row keeps its own value"
  end

  def test_sub_takes_the_amount_off_the_rows_own_value
    changed, untouched = mutating(50) { |v| v.sub 30 }

    assert_equal 20, changed
    assert_equal 50, untouched, "the other live row keeps its own value"
  end

  # --- the mutators that round-trip through a scratch variable ---

  def test_approach_moves_the_row_toward_the_target_by_one_step
    changed, untouched = mutating(10) { |v| v.approach 80, 2 }

    assert_equal 12, changed
    assert_equal 10, untouched, "the other live row keeps its own value"
  end

  def test_approach_lands_on_the_target_rather_than_passing_it
    changed, = mutating(79) { |v| v.approach 80, 5 }

    assert_equal 80, changed, "a step longer than the distance left stops at the target"
  end

  def test_abs_makes_a_negative_row_positive_and_leaves_a_positive_one_alone
    changed, untouched = mutating(-25) { |v| v.abs }

    assert_equal 25, changed
    assert_equal(-25, untouched, "the other live row keeps its own value")
    assert_equal 25, mutating(25) { |v| v.abs }.first
  end

  def test_negate_abs_makes_a_row_negative_whichever_way_it_started
    assert_equal(-25, mutating(25) { |v| v.negate_abs }.first)
    assert_equal(-25, mutating(-25) { |v| v.negate_abs }.first)
  end

  def test_flip_turns_a_row_the_other_way_round
    changed, untouched = mutating(7) { |v| v.flip }

    assert_equal(-7, changed)
    assert_equal 7, untouched, "the other live row keeps its own value"
    assert_equal 7, mutating(-7) { |v| v.flip }.first, "and back again"
  end

  # Several rows mutated in the same pass, each by its own amount: the scratch variable
  # the round-trip borrows is reused every pass, so a value left behind in it would show
  # up here as one row wearing another's number.
  def test_each_row_keeps_its_own_value_when_they_all_round_trip_in_one_pass
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      var :first, 0
      var :second, 0
      var :third, 0
      rows = pool :row, v: 0, tag: 0, capacity: 8
      rows.spawn v: -10, tag: 1
      rows.spawn v: -20, tag: 2
      rows.spawn v: -30, tag: 3
      rows.each do |row|
        row.v.abs
        (row.tag == 1).then { set :first, row.v }
        (row.tag == 2).then { set :second, row.v }
        (row.tag == 3).then { set :third, row.v }
      end
      halt
    end
    b.emit_pending_functions
    i = Reference.new.run(b.program)

    assert_equal [10, 20, 30], [i[:first], i[:second], i[:third]]
  end

  # THE CONSOLE RUNS IT THE SAME WAY. A marker is drawn at each row's own field, so
  # where the pixels land is the number the console worked out. One row takes the
  # direct write (`sub`), the other the scratch round-trip (`abs`) from a negative
  # start that no coordinate could hold.
  def test_the_console_mutates_a_row_field_the_same_way
    program = marker_program

    i = Reference.new.run(program)
    assert_equal Color.resolve(:green), i.screen.pixel(60, 40), "90 less 30"
    assert_equal Color.resolve(:green), i.screen.pixel(30, 60), "-30 made positive"

    assert_backends_agree(program, frames: 1)
  end

  # Two rows, mutated by which row they are, each drawing itself where it ended up.
  def marker_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      rows = pool :row, x: 0, y: 0, capacity: 4
      rows.spawn x: 90, y: 40
      rows.spawn x: -30, y: 60
      rows.each do |row|
        (row.y == 40).then { row.x.sub 30 }
        (row.y == 60).then { row.x.abs }
        draw_rect_at row.x, row.y, 4, 4, :green
      end
      halt
    end
    b.emit_pending_functions
    b.program
  end
end
