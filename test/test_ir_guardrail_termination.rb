# frozen_string_literal: true

require "test_helper"

require "stringio"

# The termination guardrail: a program whose top-level flow just ends — no halt,
# no forever-loop — runs off into garbage memory. It catches this on the IR (where
# it's exact) rather than by scanning finished machine code for a backward branch.
# Assert which programs warn and which don't, by whether control can fall off the
# end.
class TestIRGuardrailTermination < Minitest::Test
  include RubyGBA::IR::Build

  Guardrails = RubyGBA::IR::Guardrails

  def termination_warnings(prog)
    Guardrails::Validator.new.run(prog, autofix: false).warnings
                         .select { |w| w.check == :termination }
  end

  def test_a_program_that_falls_off_the_end_warns
    prog = program(screen(:bitmap), clear_screen(:black))
    warnings = termination_warnings(prog)

    assert_equal 1, warnings.size
    assert_match(/halt|game_loop/, warnings.first.message, "the message names the fix")
    assert_same prog.children.last, warnings.first.node,
                "it blames the last line that runs — where the missing `halt` goes"
  end

  def test_ending_in_halt_is_fine
    assert_empty termination_warnings(program(screen(:bitmap), clear_screen(:black), halt))
  end

  def test_ending_in_a_forever_loop_is_fine
    prog = program(screen(:bitmap), loop_(wait_vblank, clear_screen(:black)))
    assert_empty termination_warnings(prog), "a game_loop never falls through"
  end

  def test_a_call_into_a_looping_func_does_not_fall_through
    # `call :game` where :game loops forever never returns, so the program stops
    # there — no false "runs off the end" warning.
    prog = program(
      screen(:bitmap),
      func(:game, loop_(wait_vblank)),
      call(:game),
    )
    assert_empty termination_warnings(prog)
  end

  def test_a_call_into_a_returning_func_still_falls_off_the_end
    # :setup returns, so after the call control falls off the end.
    prog = program(
      screen(:bitmap),
      func(:setup, set(:x, 1)),
      call(:setup),
    )
    assert_equal 1, termination_warnings(prog).size
  end

  def test_definitions_after_the_flow_are_not_the_terminator
    # Funcs are appended after the main flow but don't execute in line; the loop
    # is still what stops the program (mirrors how pong is built).
    prog = program(
      screen(:bitmap),
      loop_(wait_vblank),
      func(:helper, set(:x, 1)), # a trailing definition, not a fall-through
    )
    assert_empty termination_warnings(prog)
  end

  def test_a_trailing_raw_block_is_treated_as_opaque
    # raw might hand-roll its own halt/loop; don't warn on what we can't inspect.
    prog = program(screen(:bitmap), clear_screen(:black), raw("\x00\x00\x00\x00".b))
    assert_empty termination_warnings(prog)
  end

  def test_a_call_cycle_without_a_stop_still_warns_and_terminates
    # Mutual recursion that never halts/loops: the cycle guard must stop the walk,
    # and since neither func actually stops, the program still falls off the end.
    prog = program(
      screen(:bitmap),
      func(:a, call(:b)),
      func(:b, call(:a)),
      call(:a),
    )
    assert_equal 1, termination_warnings(prog).size
  end

  # ---- at build time -------------------------------------------------------

  def test_build_warns_when_a_program_forgets_to_halt
    err = StringIO.new
    RubyGBA.build("TERM", code: "BTRM", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      clear_screen :black # draws, then just ends
    end

    assert_match(/end of your code/i, err.string)
  end

  def test_build_is_quiet_for_a_program_that_halts
    err = StringIO.new
    RubyGBA.build("TERM", code: "BTRM", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      clear_screen :black
      halt
    end

    assert_empty err.string
  end
end
