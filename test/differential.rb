# frozen_string_literal: true

require "test_helper"

# Differential testing: run the SAME program on both backends and compare the WHOLE screen,
# pixel for pixel. The check is the library's, shipped to every game with its test helper (see
# VBlank::Testing::Pictures); this suite's tests have always called it Differential, and it is
# the same module, so a game and this suite cannot drift apart.
Differential = VBlank::Testing::Pictures
