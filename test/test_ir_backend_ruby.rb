# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# The Ruby backend: run hand-built IR::Build programs in Ruby and assert the
# resulting variable state — no hardware, no emulator, no ROM.
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

  def test_if_runs_only_when_condition_is_nonzero
    i = run_ir(program(
      set(:x, 5),
      if_(binop(:>, var_ref(:x), int(0)), set(:hit, 1)),
      if_(binop(:<, var_ref(:x), int(0)), set(:miss, 1)),
    ))
    assert_equal 1, i[:hit]
    assert_equal 0, i[:miss]
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

  def test_label_is_an_inert_marker
    assert_equal 1, run_ir(program(label(:start), set(:x, 1)))[:x]
  end

  def test_call_to_undefined_func_raises
    assert_raises(Ruby::ProgramError) { run_ir(program(call(:ghost))) }
  end

  def test_draw_ops_are_rejected_by_the_core
    err = assert_raises(Ruby::ProgramError) { run_ir(program(pixel(1, 2, :red))) }
    assert_match(/hardware/, err.message)
  end
end
