# frozen_string_literal: true

require "test_helper"

require "conformance_fixture"

# The coverage guard on the interpreter itself: it runs the whole kitchen-sink fixture to its
# halt, and refuses the one kind it has no CPU for. That the fixture covers every kind is in
# test/all/vblank/ir/test_cross_backend_conformance.rb.
class TestCrossBackendConformanceInterpreter < Minitest::Test
  def test_ruby_interpreter_runs_the_whole_fixture
    # Any feature the interpreter can't execute raises ProgramError from its
    # "cannot execute ..." branch and fails here. Reaching the terminal halt
    # (not the step budget) proves the whole top-to-bottom flow ran.
    interp = Reference.new.run(ConformanceFixture.program, max_steps: 10_000)

    refute interp.stopped_at_budget?,
           "the fixture should sync-then-halt cleanly, not run out the step budget"
  end

  # ---- the one hardware-only exception, pinned explicitly ----

  def test_raw_is_hardware_only_the_interpreter_refuses_it
    # `raw` is native bytes — the portable interpreter has no CPU to run them, so
    # reaching one must raise, not silently pass. (In the fixture it's kept in an
    # uncalled func, so it's never reached there.)
    err = assert_raises(Reference::ProgramError) do
      Reference.new.run(VBlank::IR::Build.program(VBlank::IR::Build.raw("\x00\x00\x00\x00".b)))
    end
    assert_match(/cannot execute|raw/i, err.message)
  end
end
