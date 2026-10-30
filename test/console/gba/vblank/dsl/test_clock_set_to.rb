# frozen_string_literal: true

require "test_helper"
require "clock_tests"

# SETTING THE CLOCK, on the Advance: the tests every console with a clock plays (ClockSetToTests in
# test/clock_tests.rb). What only the Advance's chip does is in test_clock_set_to_on_the_advance.rb,
# and the Color's twin of this file is test/console/gbc/vblank/dsl/test_clock_set_to_on_the_color.rb.
class TestClockSetTo < Minitest::Test
  include ClockSetToTests
end
