# frozen_string_literal: true

require "test_helper"

# A ROUTINE BIGGER THAN A BANK. The Color sees its cartridge 16K at a time, and a routine has to be
# in one bank whole, so a routine of the game's that comes to more than a bank is cut into parts,
# each a routine of its own in whatever bank it fits, called where its statements stood
# (Backends::RoutineCuts). The checked run holds every variable to the interpreter, so a part run
# twice, out of order or not at all shows.
class TestGBCBigRoutines < Minitest::Test
  GBC = VBlank::IR::Backends::GBC
  Build = VBlank::IR::Build

  # Adding a number to a variable is three instructions a byte of its four on the Color, so 4000 of
  # them are well past a bank, and past where a routine is cut (Lowering::MOST_ROUTINE_BYTES).
  MANY = 4000

  private def additions(name, count) = Array.new(count) { Build.add(name, 1) }

  private def checked(*body, frames: 2)
    program = Build.program(*body, Build.loop_(Build.wait_vblank))
    program.console = :gbc
    GBC::CheckedRun.new.run(program, frames: frames)
  end

  def test_a_routine_bigger_than_a_bank_runs_every_statement_once
    run = checked(Build.func(:big, *additions(:x, MANY)), Build.call(:big))

    assert_equal MANY, run[:x]
  end

  # A statement too big to move whole has what it holds cut instead.
  def test_an_if_and_a_repeat_bigger_than_a_bank_have_what_they_hold_cut
    pick = Build.if_(Build.binop(:==, Build.var_ref(:n), Build.int(1)), *additions(:x, MANY))
    pick.else = Build.else_(*additions(:y, MANY))
    run = checked(Build.set(:n, 1), pick, Build.repeat(3, :i, *additions(:z, MANY)))

    assert_equal [MANY, 0, 3 * MANY], [run[:x], run[:y], run[:z]]
  end

  # A timer's handler bigger than a bank is cut the same way: at 60 ticks a second it runs once a
  # frame.
  def test_a_timer_handler_bigger_than_a_bank_runs
    run = checked(Build.on_timer(:tick, *additions(:x, MANY)), Build.timer_start(:tick, 60), frames: 3)

    assert_operator run[:x], :>=, MANY
  end
end
