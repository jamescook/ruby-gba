# frozen_string_literal: true

require "test_helper"

# The var/set/add/sub DSL gives each named variable a fixed IWRAM slot and
# exposes it through var_address / variables. These tests cover that allocation
# and introspection. The behavior of the operations themselves — that `add`
# really adds — is covered by the backend tests, which run the lowered ROM.
class TestVariables < Minitest::Test
  include RubyGBA::Console::Hardware

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
      set! :ball_x, 200
    end

    # Re-setting a variable reuses its slot rather than allocating a new one.
    assert_equal IWRAM_START, builder.var_address(:ball_x)
    assert_equal 1, builder.variables.size
  end

  # Two parts of a game that each declare a scratch `_seen` share ONE variable, and
  # nothing about the program says so. One holding a fraction and the other a whole
  # number is the case that gave a wrong picture rather than a build error.
  def test_one_name_declared_as_a_fraction_and_a_whole_number_names_both_lines
    first = __LINE__ + 3
    error = assert_raises(ArgumentError) do
      build_with_builder do
        var :_seen, 0.0
        var :_seen, 0
      end
    end

    assert_includes error.message, ":_seen"
    assert_includes error.message, "do not agree"
    assert_includes error.message, "test_variables.rb:#{first}"
    assert_includes error.message, "test_variables.rb:#{first + 1}"
  end

  def test_one_name_declared_with_two_different_numbers_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      build_with_builder do
        var :lives, 3
        var :lives, 5
      end
    end

    assert_includes error.message, "do not agree"
  end

  # A variable kept across power-off and a plain one with the same name are still one
  # variable, so the plain one would quietly be saved too.
  def test_a_saved_and_a_plain_declaration_that_differ_name_both_lines
    error = assert_raises(ArgumentError) do
      build_with_builder do
        save_var :best, 5
        var :best, 0
      end
    end

    assert_includes error.message, ":best"
  end

  # A helper that declares its state and is called from two places says the same thing
  # twice, and that stays one variable with nothing said.
  def test_one_name_declared_the_same_way_twice_is_one_variable
    builder = build_with_builder do
      2.times { var :_seen, 0 }
    end

    assert_equal 1, builder.variables.size
  end

  def test_set_auto_declares_variable
    builder = build_with_builder do
      set! :counter, 42
    end

    assert_equal IWRAM_START, builder.var_address(:counter)
  end

  def test_variables_returns_all_vars
    builder = build_with_builder do
      set! :x, 10
      set! :y, 20
    end

    vars = builder.variables
    assert_equal 2, vars.size
    assert_equal IWRAM_START,     vars[:x][:address]
    assert_equal IWRAM_START + 4, vars[:y][:address]
  end

  def test_set_then_set_reuses_address
    builder = build_with_builder do
      set! :x, 10
      set! :x, 20
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
      add_var! :nope, 1
    end

    assert builder.variables.key?(:nope)
  end

  def test_sub_var_auto_declares
    builder = build_with_builder do
      sub_var! :nope, 1
    end

    assert builder.variables.key?(:nope)
  end

  # Both sides of a variable-to-variable op get a slot, so the operand is usable
  # even if it was first mentioned here.
  def test_add_var_declares_a_variable_operand
    builder = build_with_builder do
      add_var! :counter, :step
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
        add! :ticks, 1 # ++ every frame
      end
    end
    builder.emit_pending_functions

    i = RubyGBA::IR::Backends::Reference.new.run(builder.program, max_steps: 5_000)
    assert_operator i[:ticks], :>, 1,
                    "var's initializer runs once at boot, so the counter accumulates rather than resetting to 0 each frame"
  end
end
