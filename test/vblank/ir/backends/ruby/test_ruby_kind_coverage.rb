# frozen_string_literal: true

require "test_helper"
require "conformance_fixture"

# Every runtime function a game written as Ruby calls is one the Ruby runtime defines, for the
# driver with no window that the tests play and for the window a person plays in. Which kinds are
# written at all is the native lowering's to say (Ruby::Lowering inherits its tables, and
# test_native_kind_coverage.rb holds them); what only this lowering can get wrong is a runtime
# with a function missing, which a game reaching it would be refused for (Ruby::RuntimeGap).
class TestRubyKindCoverage < Minitest::Test
  Ruby = VBlank::IR::Backends::Ruby

  # The kitchen-sink fixture touches every kind, so its Ruby calls everything a game can call.
  def test_every_runtime_function_a_game_calls_is_defined
    drivers = { "the tests' driver" => Ruby::HEADLESS_FUNCTIONS, "the window's driver" => Ruby::LIVE_FUNCTIONS }
    gaps = drivers.transform_values do |functions|
      Ruby::Lowering.new(ConformanceFixture.program).text_and_gaps(functions).last
    end

    assert_equal({ "the tests' driver" => [], "the window's driver" => [] }, gaps)
  end
end
