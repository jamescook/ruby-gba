# frozen_string_literal: true

require "test_helper"
require "support/suites"

# Fails when anything but `rake test:native` runs it. It sits with the native backend's tests,
# so the day `rake test` starts picking those up — a glob widened, an exclusion dropped — this
# is one of the files it picks up, and it says so.
class TestNativeSuite < Minitest::Test
  def test_only_rake_test_native_runs_the_native_tests
    assert_equal "1", ENV.fetch(TestSuites::NATIVE_RUN, nil),
                 "a native backend test ran outside `rake test:native`; `rake test` must leave " \
                 "#{TestSuites::NATIVE_DIR} alone"
  end
end
