# frozen_string_literal: true

require "test_helper"
require_relative "support/suites"

# `rake test` must never run the native backend's tests: they need zig, and native trails the
# other two backends on purpose (see TestSuites). This holds the line on the real tree, so a
# native test filed in the wrong place, or a glob that widens, fails here.
class TestSuitesSplit < Minitest::Test
  def test_the_native_suite_has_tests
    refute_empty TestSuites.native
  end

  def test_rake_test_runs_no_native_test
    assert_empty TestSuites.main & TestSuites.native
  end
end
