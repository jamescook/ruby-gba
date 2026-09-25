# frozen_string_literal: true

# THE CONSOLE ITSELF, NAMED: where its memory is, the addresses of the registers that drive the
# display, the sound, the copying engines and the timers, and the flags written into them. Nothing
# here does anything; it is the table every part that talks to the hardware reads its numbers from,
# so it needs nothing loaded before it.

require_relative "console/hardware" # the register addresses, flags and memory map
