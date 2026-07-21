# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"

# The vblank-sync guardrail: a game loop with no reachable frame sync gets a
# soft, plain-language warning (not an error — the build still succeeds). These
# assert the *behavior* — which loops warn and which don't, via reachability —
# and that the warning reaches RubyGBA.build's err stream so a real build nudges.
class TestIRGuardrailVblankSync < Minitest::Test
  include RubyGBA::IR::Build

  Guardrails = RubyGBA::IR::Guardrails

  # The vblank-sync warnings the checker raises for a program.
  def vblank_warnings(prog)
    Guardrails::Validator.new.run(prog, autofix: false).warnings
                         .select { |w| w.check == :vblank_sync }
  end

  # ---- reachability: which loops warn -------------------------------------

  def test_a_loop_with_no_frame_sync_warns
    warnings = vblank_warnings(program(display(:bitmap), loop_(clear_screen(:black))))

    assert_equal 1, warnings.size
    assert_match(/wait_vblank/, warnings.first.message, "the warning names the fix")
  end

  def test_a_loop_that_waits_directly_is_fine
    prog = program(display(:bitmap), loop_(wait_vblank, clear_screen(:black)))
    assert_empty vblank_warnings(prog)
  end

  def test_sync_reachable_through_a_called_func_is_fine
    prog = program(
      display(:bitmap),
      func(:sync, wait_vblank),
      loop_(call(:sync), clear_screen(:black)),
    )
    assert_empty vblank_warnings(prog), "reachability follows a call into its func"
  end

  def test_sync_reachable_through_a_case_dispatched_scene_is_fine
    prog = program(
      display(:bitmap),
      func(:_scene_play, wait_vblank, clear_screen(:black)),
      set(:state, 0),
      loop_(case_(:state, { 0 => :_scene_play })),
    )
    assert_empty vblank_warnings(prog), "reachability follows case dispatch into scenes"
  end

  def test_sync_inside_a_nested_if_counts
    prog = program(
      display(:bitmap), set(:x, 1),
      loop_(if_(binop(:>, var_ref(:x), int(0)), wait_vblank)),
    )
    assert_empty vblank_warnings(prog)
  end

  def test_sync_inside_an_else_branch_counts
    # Guards that reachability descends into the else-branch (held in :else, not
    # #children).
    branch = if_(binop(:>, var_ref(:x), int(0)), clear_screen(:black))
    branch[:else] = else_(wait_vblank)
    prog = program(display(:bitmap), set(:x, 1), loop_(branch))

    assert_empty vblank_warnings(prog)
  end

  def test_a_reachable_raw_block_suppresses_the_warning
    # raw is opaque — it may hand-roll its own sync — so we stay quiet rather than
    # cry wolf.
    prog = program(display(:bitmap), loop_(raw("\x00\x00\x00\x00".b), clear_screen(:black)))
    assert_empty vblank_warnings(prog)
  end

  def test_a_program_with_no_loop_is_not_nagged
    assert_empty vblank_warnings(program(display(:bitmap), clear_screen(:black), halt))
  end

  def test_a_call_cycle_without_sync_still_warns_and_terminates
    # Mutual recursion with no sync anywhere: the cycle guard must stop the walk
    # (not loop forever) and the loop must still warn.
    prog = program(
      display(:bitmap),
      func(:a, call(:b)),
      func(:b, call(:a)),
      loop_(call(:a)),
    )
    assert_equal 1, vblank_warnings(prog).size
  end

  # ---- the warning reaches RubyGBA.build's err stream ---------------------

  def build_err(&block)
    err = StringIO.new
    RubyGBA.build("GUARD", code: "BGRD", maker: "01", out: StringIO.new, err: err, &block)
    err.string
  end

  def test_build_nudges_a_loop_that_never_syncs
    err = build_err do
      display :bitmap
      game_loop { clear_screen :black }
    end

    assert_match(/wait_vblank/, err, "the build surfaces the warning on err")
  end

  def test_build_is_quiet_for_a_well_formed_loop
    err = build_err do
      display :bitmap
      game_loop do
        wait_vblank
        clear_screen :black
      end
    end

    assert_empty err, "a loop that syncs draws no warning"
  end
end
