# frozen_string_literal: true

require "test_helper"

# A ROUTINE BIGGER THAN A BANK. The processor runs a routine inside one 32K bank of the cartridge —
# its program counter goes round to the start of the bank rather than on into the next — so a
# routine of the game's that comes to more than that is cut into parts, each a routine of its own in
# whatever bank it fits, called where its statements stood. The checked run holds every variable
# to the interpreter, so a part run twice, out of order or not at all shows.
class TestSNESBigRoutines < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Build = VBlank::IR::Build

  # Adding to a variable is a dozen bytes or more of 65816 (it is a 32-bit number, worked two
  # bytes at a time), so 4000 of them are more than a bank holds, and well past where a routine is
  # cut, which is short of a bank (Lowering::MOST_ROUTINE_BYTES).
  MANY = 4000

  private def additions(name, count) = Array.new(count) { Build.add(name, 1) }

  private def checked(*body, frames: 2)
    program = Build.program(*body, Build.loop_(Build.wait_vblank))
    program.console = :snes
    SNES::CheckedRun.new.run(program, frames: frames)
  end

  def test_a_routine_bigger_than_a_bank_runs_every_statement_once
    run = checked(Build.func(:big, *additions(:x, MANY)), Build.call(:big))

    assert_equal MANY, run[:x]
  end

  # The game's own statements, outside any routine, cut the same way.
  def test_the_games_own_statements_bigger_than_a_bank_run
    run = checked(*additions(:x, MANY))

    assert_equal MANY, run[:x]
  end

  # A statement too big to move whole has what it holds cut instead: an `if` whose two sides are
  # each more than a bank runs the side its condition picks, and a `repeat` round more than a bank
  # runs it the number of times it says.
  def test_an_if_and_a_repeat_bigger_than_a_bank_have_what_they_hold_cut
    pick = Build.if_(Build.binop(:==, Build.var_ref(:n), Build.int(1)), *additions(:x, MANY))
    pick.else = Build.else_(*additions(:y, MANY))
    run = checked(Build.set(:n, 1), pick, Build.repeat(3, :i, *additions(:z, MANY)))

    assert_equal [MANY, 0, 3 * MANY], [run[:x], run[:y], run[:z]]
  end

  # A part that waits for the next frame: the game is held there, inside a part called from the
  # routine, and goes on from it — the first frame ends with x at MANY, the second with it at twice.
  def test_a_part_that_waits_for_the_next_frame_goes_on_from_there
    run = checked(Build.func(:big, *additions(:x, MANY), Build.wait_vblank, *additions(:x, MANY)), Build.call(:big),
                  frames: 3)

    assert_equal 2 * MANY, run[:x]
  end

  # A timer's handler bigger than a bank is cut the same way: at 60 ticks a second it runs once a
  # frame.
  def test_a_timer_handler_bigger_than_a_bank_runs
    run = checked(Build.on_timer(:tick, *additions(:x, MANY)), Build.timer_start(:tick, 60), frames: 3)

    assert_operator run[:x], :>=, MANY
  end
end
