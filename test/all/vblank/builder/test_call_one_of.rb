# frozen_string_literal: true

require "test_helper"
require "differential"

# A CALL PICKED BY NUMBER: `call [:op_end, :op_wait, ...], number: opcode`.
#
# The number comes out of data — the instruction byte of a script read from a cartridge, the
# state kept on one of thirty guards — and what it picks is a routine. The point of it is that
# it costs the same however many routines there are, where asking "is it this one?" of each in
# turn costs a test per routine, all of them every time.
module CallOneOfGames
  private def program_with(&block)
    b = VBlank::Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end
end

# This file is that it picks the RIGHT routine (from a variable, from a pooled instance's own
# field, and with every pixel of the picture held to the interpreter's), and what it refuses. That
# the Advance's cartridge reaches each routine wherever it was put, and that what it costs does
# not grow with the length of the list, is in
# test/lowering/gba/vblank/builder/test_call_one_of_cartridge.rb, which builds its games the same
# way (CallOneOfGames).
class TestCallOneOf < Minitest::Test
  include Differential
  include CallOneOfGames

  # --- it picks the right routine ---

  def test_the_number_picks_which_routine_runs
    interpreted = run_picking(2)

    assert_equal 33, interpreted[:n], "the number is a place in the list, counting from 0"
  end

  def test_the_first_routine_is_number_nought
    assert_equal 11, run_picking(0)[:n]
  end

  # A number past the end of the list names no routine, so nothing is called — the same answer
  # `show_map` and a song list give a number that names nothing. A game reading a number out of
  # data needs no test around it.
  def test_a_number_past_the_end_calls_nothing
    assert_equal 0, run_picking(3)[:n]
  end

  def test_a_number_below_nought_calls_nothing
    assert_equal 0, run_picking(-1)[:n]
  end

  # The number may be worked out where it is written, not only read out of a variable.
  def test_the_number_can_be_worked_out_on_the_spot
    program = program_with do
      screen :bitmap
      n = var :n, 0
      step = var :step, 1
      b = self
      b.func(:first) { n.set! 11 }
      b.func(:second) { n.set! 22 }
      b.func(:third) { n.set! 33 }
      game_loop { b.call %i[first second third], number: step + 1 }
    end

    assert_equal 33, game_player.run(program)[:n]
  end

  # THE CASE THE FEATURE IS FOR: each instance of a pool carries its own number, so one line
  # inside `each` runs a different routine for every one of them.
  def test_each_pooled_instance_picks_its_own_routine
    program = program_with do
      screen :bitmap
      walked = var :walked, 0
      waited = var :waited, 0
      scripts = pool :script, step: 0, capacity: 4
      b = self
      b.func(:op_walk) { walked.add! 1 }
      b.func(:op_wait) { waited.add! 1 }
      scripts.spawn(step: 0)
      scripts.spawn(step: 1)
      scripts.spawn(step: 1)
      game_loop do
        scripts.each { |s| b.call %i[op_walk op_wait], number: s.step }
        b.halt
      end
    end
    interpreted = game_player.run(program)

    assert_equal 1, interpreted[:walked]
    assert_equal 2, interpreted[:waited]
  end

  # --- and the console agrees ---

  # Each routine paints its own rectangle, so which one ran is on the screen. Every pixel of
  # both backends' pictures has to match.
  def test_both_backends_draw_what_the_number_picked
    assert_backends_agree(drawing_program, frames: 3)
  end

  # --- what it refuses ---

  def test_a_single_routine_with_a_number_says_what_number_is_for
    err = assert_raises(ArgumentError) { program_with { call :only_one, number: 2 } }

    assert_match(/calls one routine/, err.message)
    assert_match(/give a list/, err.message)
  end

  def test_a_list_with_no_number_says_to_give_one
    err = assert_raises(ArgumentError) { program_with { call %i[a b] } }

    assert_match(/no number to pick one/, err.message)
  end

  def test_an_empty_list_is_refused
    err = assert_raises(ArgumentError) { program_with { call [], number: 0 } }

    assert_match(/empty list of routines/, err.message)
  end

  def test_something_that_is_not_a_routine_name_is_refused
    err = assert_raises(ArgumentError) { program_with { call [:a, "b"], number: 0 } }

    assert_match(/name of a routine/, err.message)
  end

  # A number holding a fraction would pick by its scaled-up bits, which is not the routine
  # anybody meant.
  def test_a_number_that_holds_a_fraction_is_refused
    err = assert_raises(ArgumentError) do
      program_with do
        speed = var :speed, 1.5
        call %i[a b], number: speed
      end
    end

    assert_match(/holds a fraction/, err.message)
    assert_match(/to_i/, err.message)
  end

  def test_a_written_number_past_the_end_of_the_list_is_refused
    err = assert_raises(ArgumentError) { program_with { call %i[a b], number: 5 } }

    assert_match(/numbered 0 to 1/, err.message)
  end

  # A number written into the program picks while the cartridge is built, so it is the plain
  # call it would have been written as — no table, no test, nothing to do as the game runs.
  def test_a_written_number_picks_while_building
    program = program_with do
      screen :bitmap
      n = var :n, 0
      b = self
      b.func(:first) { n.set! 11 }
      b.func(:second) { n.set! 22 }
      game_loop { b.call %i[first second], number: 1 }
    end
    kinds = program.walk.map(&:kind)

    refute_includes kinds, :call_one_of, "a number known while building needs no dispatch"
    assert_equal 22, game_player.run(program)[:n]
  end

  def test_a_routine_the_list_names_but_nobody_defined_is_refused
    err = assert_raises(ArgumentError) do
      program_with do
        screen :bitmap
        which = var :which, 0
        b = self
        b.func(:defined) { b.halt }
        game_loop { b.call %i[defined missing], number: which }
      end
    end

    assert_match(/:missing is called but never defined/, err.message)
  end

  private

  # Three routines, each setting :n to its own number, and the number +which+ picking between
  # them. :n stays 0 when the number names none of them.
  def run_picking(which)
    program = program_with do
      screen :bitmap
      n = var :n, 0
      picked = var :picked, which
      b = self
      b.func(:first) { n.set! 11 }
      b.func(:second) { n.set! 22 }
      b.func(:third) { n.set! 33 }
      game_loop { b.call %i[first second third], number: picked }
    end
    game_player.run(program)
  end

  # The middle rectangle is painted and the others are not: one call picks the middle one, and
  # two more are given numbers that name no routine — one past the end of the list and one
  # below its start — which paint nothing. On the console those two are held back by a single
  # test. Without it the number would be read that far along the table and the call would land
  # on whatever word was there.
  def drawing_program
    program_with do
      screen :bitmap
      clear_screen :black
      picked = var :picked, 1
      past_the_end = var :past_the_end, 7
      below_the_start = var :below_the_start, -1
      b = self
      b.func(:paint_left) { b.fill_rect 10, 10, 40, 40, :red }
      b.func(:paint_middle) { b.fill_rect 100, 10, 40, 40, :green }
      b.func(:paint_right) { b.fill_rect 190, 10, 40, 40, :blue }
      game_loop do
        b.call %i[paint_left paint_middle paint_right], number: picked
        b.call %i[paint_left paint_middle paint_right], number: past_the_end
        b.call %i[paint_left paint_middle paint_right], number: below_the_start
      end
    end
  end
end
