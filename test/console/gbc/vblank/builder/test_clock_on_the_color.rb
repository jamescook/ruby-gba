# frozen_string_literal: true

require "test_helper"
require "clock_tests"

# THE DATE AND TIME, READ BY THE GAME, on the Color: the tests every console with a clock plays
# (ClockTests in test/clock_tests.rb). The Advance's twin is
# test/console/gba/vblank/builder/test_clock.rb.
class TestClockOnTheColor < Minitest::Test
  include ClockTests
end
