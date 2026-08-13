# frozen_string_literal: true

require "test_helper"

# A loop that stops as soon as it has its answer.
#
# The shape this exists for is a search — a ray marching until it meets a wall. Written as a
# counted loop guarded by a flag, every step after the answer still runs: it tests the flag,
# branches, and does nothing. A ray that hits a third of the way through pays for the other two
# thirds, and a first-person view casts one of these per strip across the screen.
class TestRepeatStopWhen < Minitest::Test
  include GembaSupport

  Build = RubyGBA::IR::Build
  LoopForm = RubyGBA::IR::Backends::GBA::LoopForm

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  def marching
    program do
      screen :bitmap
      hit = var :hit, 0
      steps = var :steps, 0
      game_loop do
        hit.set 0
        steps.set 0
        repeat(20, stop_when: hit == 1) do
          steps.add 1
          (steps >= 5).then { hit.set 1 }
        end
      end
    end
  end

  def test_it_stops_the_pass_after_the_answer_arrives
    assert_equal 5, Reference.new.run(marching, frames: 2)[:steps]
  end

  def test_a_loop_with_nothing_to_stop_for_runs_its_whole_count
    run = Reference.new.run(program do
      screen :bitmap
      n = var :n, 0
      game_loop { n.set 0; repeat(7) { n.add 1 } }
    end, frames: 2)

    assert_equal 7, run[:n]
  end

  # Asked before the body, so a loop whose answer is already in runs the body no times — the
  # same reading on both backends, which is the part that has to be pinned.
  def test_a_condition_already_true_runs_the_body_no_times
    run = Reference.new.run(program do
      screen :bitmap
      done = var :done, 1
      n = var :n, 0
      game_loop { n.set 0; repeat(9, stop_when: done == 1) { n.add 1 } }
    end, frames: 2)

    assert_equal 0, run[:n]
  end

  def test_the_console_stops_where_the_interpreter_stops
    backend = GBA.new
    rom = ROM.assemble(backend.lower(marching), title: "STOP", code: "ASTP", maker: "01")
    gba = assert_gemba_loads_rom(rom, frames: 4, vars: backend.var_addresses)

    assert_equal Reference.new.run(marching, frames: 2)[:steps], gba.var(:steps)
    assert_equal 5, gba.var(:steps)
  end

  # A loop that can stop early works its condition out in the two registers the fast shape keeps
  # its counter and limit in, so it takes the safe shape instead. Dearer per pass, and far
  # cheaper than the passes it does not make.
  def test_an_early_exit_loop_gives_up_the_fast_shape_and_a_plain_one_keeps_it
    plain = Build.repeat(Build.int(4), :i, Build.set(:n, Build.int(1)))
    early = Build.repeat(Build.int(4), :i, Build.set(:n, Build.int(1)),
                         stop_when: Build.var_ref(:done))

    assert LoopForm.registers?(plain), "a plain counted loop keeps the registers"
    refute LoopForm.registers?(early), "one that can stop early cannot"
    refute LoopForm.stops_early?(plain), "a zero stop condition is nothing to stop for"
    assert LoopForm.stops_early?(early)
  end
end
