# frozen_string_literal: true

require "test_helper"

# Each run of the suite tests ONE lowering — `rake test` the interpreter, `rake test:native` the
# game as C — and a test class runs only on the lowerings it names (`runs_on`). This class names
# none, which is every class that has not been looked at for native yet, so it fails if a native
# run ever picks it up. Its other side is test_native_suite.rb, which names only native and fails
# if `rake test` ever runs it.
class TestSuitesSplit < Minitest::Test
  def test_a_class_that_names_no_lowering_runs_only_on_the_interpreter
    assert_equal :reference, TestSuites::LOWERING,
                 "a test class that never said `runs_on :native` ran on a #{TestSuites::LOWERING} run"
  end
end
