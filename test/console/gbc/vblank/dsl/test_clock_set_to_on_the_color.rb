# frozen_string_literal: true

require "test_helper"
require "clock_tests"

# SETTING THE CLOCK, on the Color: the tests every console with a clock plays (ClockSetToTests in
# test/clock_tests.rb). What only the Color's chip does is in
# test/lowering/gbc/vblank/ir/backends/gbc/test_gbc_clock.rb, and the Advance's twin of this file
# is test/console/gba/vblank/dsl/test_clock_set_to.rb.
class TestClockSetToOnTheColor < Minitest::Test
  include ClockSetToTests
end
