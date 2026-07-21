# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# The Ruby backend, logic core: run hand-built IR::Build programs in Ruby and
# assert the resulting variable state — control flow, arithmetic, calls. The
# simulated hardware (framebuffer, input) is exercised separately in
# test_ir_backend_ruby_hardware.rb; here there's no screen and no gamepad.
class TestIRBackendRuby < Minitest::Test
  include RubyGBA::IR::Build

  Ruby = RubyGBA::IR::Backends::Ruby
  Int32 = RubyGBA::IR::Int32

  def run_ir(node, **opts)
    Ruby.new.run(node, **opts)
  end

  def test_set_and_read
    assert_equal 5, run_ir(program(set(:x, 5)))[:x]
  end

  def test_unwritten_variable_reads_zero
    assert_equal 0, run_ir(program)[:nope]
  end

  def test_arithmetic_with_immediates_and_vars
    i = run_ir(program(
      set(:x, 10),
      set(:y, 3),
      add(:x, 5),   # 15
      sub(:x, :y),  # 12
    ))
    assert_equal 12, i[:x]
  end

  def test_expression_assignment_evaluates_the_ast
    i = run_ir(program(
      set(:y, 40),
      set(:c, binop(:+, var_ref(:y), int(2))),
    ))
    assert_equal 42, i[:c]
  end

  def test_arithmetic_wraps_like_int32
    i = run_ir(program(set(:x, Int32::MAX), add(:x, 1)))
    assert_equal Int32::MIN, i[:x]
  end

  def test_copy_negate_and_clamp
    i = run_ir(program(
      set(:a, 7), copy(:b, :a), negate(:b), # b = -7
      set(:c, 500), clamp(:c, 0, 100),      # c = 100
    ))
    assert_equal(-7, i[:b])
    assert_equal 100, i[:c]
  end

  def test_abs_and_negate_abs
    i = run_ir(program(
      set(:a, 7), abs(:a),                     # positive stays: 7
      set(:b, 9), negate(:b), abs(:b),         # -9 -> 9
      set(:c, 4), negate_abs(:c),              # 4 -> -4
      set(:d, 6), negate(:d), negate_abs(:d),  # -6 stays -6 (already negative)
    ))
    assert_equal 7, i[:a]
    assert_equal 9, i[:b]
    assert_equal(-4, i[:c])
    assert_equal(-6, i[:d])
  end

  def test_abs_and_negate_abs_leave_zero_alone
    i = run_ir(program(set(:z, 0), abs(:z), set(:w, 0), negate_abs(:w)))
    assert_equal 0, i[:z]
    assert_equal 0, i[:w]
  end

  def test_if_runs_only_when_condition_is_nonzero
    i = run_ir(program(
      set(:x, 5),
      if_(binop(:>, var_ref(:x), int(0)), set(:hit, 1)),
      if_(binop(:<, var_ref(:x), int(0)), set(:miss, 1)),
    ))
    assert_equal 1, i[:hit]
    assert_equal 0, i[:miss]
  end

  def test_if_else_runs_the_else_branch_when_false
    # x = 1: the > 5 test is false, so only the else branch runs.
    taken = if_(binop(:>, var_ref(:x), int(5)), set(:hi, 1))
    taken[:else] = else_(set(:lo, 1))

    i = run_ir(program(set(:x, 1), taken))
    assert_equal 0, i[:hi], "the then-branch must not run when the condition is false"
    assert_equal 1, i[:lo], "the else-branch runs when the condition is false"
  end

  def test_if_else_runs_the_then_branch_when_true
    taken = if_(binop(:>, var_ref(:x), int(5)), set(:hi, 1))
    taken[:else] = else_(set(:lo, 1))

    i = run_ir(program(set(:x, 9), taken))
    assert_equal 1, i[:hi]
    assert_equal 0, i[:lo], "the else-branch must not run when the condition is true"
  end

  def test_reads_a_byte_from_embedded_data
    # A named blob is embedded once and its bytes are readable by (name, index).
    i = run_ir(program(
      data(:blob, "\x07\x2a\x63".b),
      set(:x, data_byte(:blob, 0)),
      set(:y, data_byte(:blob, 1)),
      set(:z, data_byte(:blob, 2)),
    ))
    assert_equal 0x07, i[:x]
    assert_equal 0x2a, i[:y]
    assert_equal 0x63, i[:z]
  end

  def test_bitmap_pixels_are_embedded_and_readable
    # A bitmap's pixels ride the same embedding path as a raw data blob, so they
    # are readable by (name, index) — this is what blit will draw.
    i = run_ir(program(
      bitmap(:friend, width: 2, height: 1, pixels: "\x1F\x00\x00\x7C".b),
      set(:lo, data_byte(:friend, 0)),
      set(:hi, data_byte(:friend, 3)),
    ))
    assert_equal 0x1F, i[:lo]
    assert_equal 0x7C, i[:hi]
  end

  def test_division_truncates_toward_zero
    # Matches the console's BIOS Div (and C): quotient rounds toward zero, so a
    # negative result truncates up, never down like Ruby's floor division.
    i = run_ir(program(
      set(:a, 20), set(:qa, binop(:/, var_ref(:a), int(3))),   #  6
      set(:b, -7), set(:qb, binop(:/, var_ref(:b), int(2))),   # -3 (not -4)
      set(:c, 7),  set(:qc, binop(:/, var_ref(:c), int(-2))),  # -3
    ))
    assert_equal 6, i[:qa]
    assert_equal(-3, i[:qb])
    assert_equal(-3, i[:qc])
  end

  def test_signed_comparison_flows_through_conditions
    # x = -1 (0xFFFF_FFFF). Signed, -1 < 1 is true — the opposite of comparing
    # the raw bits as unsigned.
    i = run_ir(program(
      set(:x, 0xFFFF_FFFF),
      if_(binop(:<, var_ref(:x), int(1)), set(:neg, 1)),
    ))
    assert_equal(-1, i[:x])
    assert_equal 1, i[:neg]
  end

  def test_loop_runs_to_completion_via_halt
    i = run_ir(program(
      set(:x, 0),
      loop_(
        add(:x, 1),
        if_(binop(:>=, var_ref(:x), int(5)), halt),
      ),
    ))
    assert_equal 5, i[:x]
    refute i.stopped_at_budget?
  end

  def test_infinite_loop_is_bounded_by_the_step_budget
    i = run_ir(program(loop_(add(:x, 1))), max_steps: 50)
    assert i.stopped_at_budget?
    assert_operator i[:x], :>, 0
  end

  def test_forward_referenced_call_resolves
    # inc is called before it is defined later in the same program
    i = run_ir(program(
      set(:x, 0),
      call(:inc),
      call(:inc),
      func(:inc, add(:x, 1)),
    ))
    assert_equal 2, i[:x]
  end

  def test_call_to_undefined_func_raises
    assert_raises(Ruby::ProgramError) { run_ir(program(call(:ghost))) }
  end

  def test_raw_bytes_cannot_run_in_the_interpreter
    # raw target code is a GBA-only escape hatch; the headless interpreter has no
    # way to execute machine bytes, so it refuses them with a clear error.
    err = assert_raises(Ruby::ProgramError) { run_ir(program(raw("\x00\x00\x00\x00".b))) }
    assert_match(/raw .*escape hatch|GBA-only/i, err.message)
  end

  def test_case_var_dispatches_to_the_matching_scene
    i = run_ir(program(
      set(:state, 1),
      set(:hit, 0),
      case_(:state, 0 => :title, 1 => :playing),
      func(:title, set(:hit, 100)),
      func(:playing, set(:hit, 200)),
    ))
    assert_equal 200, i[:hit] # state == 1 ran :playing, not :title
  end

  def test_case_var_with_no_matching_clause_does_nothing
    i = run_ir(program(
      set(:state, 9),
      set(:hit, 0),
      case_(:state, 0 => :title),
      func(:title, set(:hit, 1)),
    ))
    assert_equal 0, i[:hit]
  end
end
