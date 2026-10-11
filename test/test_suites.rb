# frozen_string_literal: true

require "test_helper"
require "support/suites"

# The two lists of test files the suites run. That `rake test` really leaves the native ones
# alone is proved from the other side, by a native test that fails when anything but `rake
# test:native` starts it (test/ruby_gba/ir/backends/native/test_native_suite.rb).
class TestSuitesSplit < Minitest::Test
  def test_the_native_suite_has_tests
    refute_empty TestSuites.native
  end

  def test_rake_test_runs_no_native_test
    assert_empty TestSuites.main & TestSuites.native
  end
end
