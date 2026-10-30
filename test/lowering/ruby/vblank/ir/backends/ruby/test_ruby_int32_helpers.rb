# frozen_string_literal: true

require "test_helper"
require "int32_cases"

# The Ruby lowering's arithmetic (runtime/rg_int32.rb) gives the answer IR::Int32 gives, for the
# values where a Ruby Integer, which never wraps, and a 32-bit whole number are most likely to part
# ways (Int32Cases). The runtime is Ruby, so it is loaded into a class here and asked directly.
class TestRubyInt32Helpers < Minitest::Test
  Ruby = VBlank::IR::Backends::Ruby
  CASES = Int32Cases.cases.freeze

  # Each calculation's name, by the runtime function that does it.
  HELPERS = { "add" => :rg_add, "sub" => :rg_sub, "mul" => :rg_mul, "neg" => :rg_neg, "abs" => :rg_abs,
              "clamp" => :rg_clamp, "div" => :rg_div, "mod" => :rg_mod, "mul_fix" => :rg_mul_fix,
              "div_fix" => :rg_div_fix, "bit_and" => :rg_and, "bit_or" => :rg_or, "bit_xor" => :rg_xor,
              "bit_not" => :rg_not, "shift_left" => :rg_shl, "shift_right" => :rg_shr, "lt" => :rg_lt,
              "le" => :rg_le, "gt" => :rg_gt, "ge" => :rg_ge, "eq" => :rg_eq, "ne" => :rg_ne, "both" => :rg_both,
              "either" => :rg_either, "to_byte" => :rg_to_byte, "to_half" => :rg_to_half }.freeze

  def test_every_helper_gives_int32s_answer
    wrong = Int32Cases.wrong_answers(CASES, calculate(CASES))

    assert_empty wrong.first(10), "#{wrong.size} of #{CASES.size} calculations disagree"
  end

  def test_dividing_by_zero_gives_the_consoles_answer
    calculations, answers = Int32Cases::BY_ZERO.transpose

    assert_equal answers, calculate(calculations)
  end

  private

  def calculate(cases)
    runtime = Class.new { class_eval(File.read(File.join(Ruby::RUNTIME_DIR, "rg_int32.rb")), "rg_int32.rb") }.new
    cases.map do |name, a, b, c|
      helper = runtime.method(HELPERS.fetch(name))
      helper.call(*[a, b, c].first(helper.arity))
    end
  end
end
