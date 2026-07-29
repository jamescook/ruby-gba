# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# The var/set/add/sub DSL gives each named variable a fixed IWRAM slot and
# exposes it through var_address / variables. These tests cover that allocation
# and introspection. The behavior of the operations themselves — that `add`
# really adds — is covered by the backend tests, which run the lowered ROM.
class TestVariables < Minitest::Test
  include RubyGBA::Constants

  # Build through the DSL and hand back the Builder for inspection.
  def build_with_builder(&block)
    builder = RubyGBA::Builder.new
    builder.instance_eval(&block)
    builder
  end

  # ========================================================================
  # var — declaration and allocation
  # ========================================================================

  def test_var_allocates_iwram_address
    builder = build_with_builder do
      var :ball_x, 100
    end

    assert_equal IWRAM_START, builder.var_address(:ball_x)
  end

  def test_var_sequential_allocation
    builder = build_with_builder do
      var :ball_x, 100
      var :ball_y, 80
      var :score, 0
    end

    assert_equal IWRAM_START,     builder.var_address(:ball_x)
    assert_equal IWRAM_START + 4, builder.var_address(:ball_y)
    assert_equal IWRAM_START + 8, builder.var_address(:score)
  end

  def test_var_called_twice_keeps_the_same_address
    builder = build_with_builder do
      var :ball_x, 100
      set :ball_x, 200
    end

    # Re-setting a variable reuses its slot rather than allocating a new one.
    assert_equal IWRAM_START, builder.var_address(:ball_x)
    assert_equal 1, builder.variables.size
  end

  def test_set_auto_declares_variable
    builder = build_with_builder do
      set :counter, 42
    end

    assert_equal IWRAM_START, builder.var_address(:counter)
  end

  def test_variables_returns_all_vars
    builder = build_with_builder do
      set :x, 10
      set :y, 20
    end

    vars = builder.variables
    assert_equal 2, vars.size
    assert_equal IWRAM_START,     vars[:x][:address]
    assert_equal IWRAM_START + 4, vars[:y][:address]
  end

  def test_set_then_set_reuses_address
    builder = build_with_builder do
      set :x, 10
      set :x, 20
    end

    # Second set doesn't allocate a new address
    assert_equal IWRAM_START, builder.var_address(:x)
    assert_equal 1, builder.variables.size
  end

  # ========================================================================
  # add_var / sub_var — auto-declaration
  # ========================================================================

  def test_add_var_auto_declares
    builder = build_with_builder do
      add_var :nope, 1
    end

    assert builder.variables.key?(:nope)
  end

  def test_sub_var_auto_declares
    builder = build_with_builder do
      sub_var :nope, 1
    end

    assert builder.variables.key?(:nope)
  end

  # Both sides of a variable-to-variable op get a slot, so the operand is usable
  # even if it was first mentioned here.
  def test_add_var_declares_a_variable_operand
    builder = build_with_builder do
      add_var :counter, :step
    end

    assert builder.variables.key?(:counter)
    assert builder.variables.key?(:step)
  end

  # A declaration initializes ONCE, at program start — not every time the declaration
  # runs. Declared inside a loop, `var :ticks, 0` doesn't re-zero the counter each frame,
  # so it accumulates; if the initializer ran every frame it would be stuck at 1. This is
  # what lets a game object declare its own state in setup that lives inside a scene.
  def test_var_initializes_once_even_when_declared_inside_a_loop
    builder = build_with_builder do
      screen :bitmap
      game_loop do
        wait_vblank
        var :ticks, 0 # declared inside the per-frame loop
        add :ticks, 1 # ++ every frame
      end
    end
    builder.emit_pending_functions

    i = RubyGBA::IR::Backends::Ruby.new.run(builder.program, max_steps: 5_000)
    assert_operator i[:ticks], :>, 1,
                    "var's initializer runs once at boot, so the counter accumulates rather than resetting to 0 each frame"
  end
end
