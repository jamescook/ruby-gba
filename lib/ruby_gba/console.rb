# frozen_string_literal: true

# THE CONSOLES THEMSELVES, NAMED: what a game can tell about each one (its screen, its buttons, how
# many sprites it shows, what it does with each verb), and for each the addresses of the registers
# that drive its display, sound, copying engines and timers, and the flags written into them.
# Nothing here does anything; it is the table every part that talks to the hardware reads its
# numbers from, so it needs nothing loaded before it.

require_relative "console/hardware" # the register addresses, flags and memory map
require_relative "console/description" # what a game can tell about a console: its screen, buttons, sprites
require_relative "console/gbc_features" # what each verb does on a Game Boy Color: works, degrades or refused
