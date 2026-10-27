# frozen_string_literal: true

require "test_helper"
require "int32_cases"

# The JavaScript arithmetic (runtime/rg_int32.js) gives the answer IR::Int32 gives, for the values
# where a float and a 32-bit whole number are most likely to part ways (Int32Cases).
#
# Every calculation goes through one run of node (int32_harness.js).
class TestJSInt32Helpers < Minitest::Test
  JS = VBlank::IR::Backends::JS
  HARNESS = Ractor.make_shareable(File.expand_path("int32_harness.js", __dir__))
  RUNTIME = Ractor.make_shareable(File.join(JS::RUNTIME_DIR, "rg_int32.js"))
  CASES = Int32Cases.cases.freeze

  def test_every_helper_gives_int32s_answer
    wrong = Int32Cases.wrong_answers(CASES, calculate(CASES))

    assert_empty wrong.first(10), "#{wrong.size} of #{CASES.size} calculations disagree"
  end

  # Dividing by zero follows the console's own divide routine, so a game that does it behaves the
  # same in a browser as on the cartridge.
  def test_dividing_by_zero_gives_the_consoles_answer
    calculations, answers = Int32Cases::BY_ZERO.transpose

    assert_equal answers, calculate(calculations)
  end

  private

  def calculate(cases)
    input = cases.map { |name, a, b, c| "#{name} #{a} #{b} #{c}\n" }.join
    JS::Node.run_program(HARNESS, args: [RUNTIME], input: input).lines.map(&:to_i)
  end
end
