# frozen_string_literal: true

# THE CONSOLES THEMSELVES, NAMED: what a game can tell about each one (its screen, its buttons, how
# many sprites it shows, what it does with each verb), and for each the addresses of the registers
# that drive its display, sound, copying engines and timers, and the flags written into them; and
# which of the library's parts serve each one (Console::Kit). Nothing here does anything; it
# is the table every part that talks to the hardware reads its numbers from, and the parts it
# names are only asked for once everything is loaded, so it needs nothing loaded before it.

require_relative "console/hardware" # the register addresses, flags and memory map
require_relative "console/sample_clock" # the rates a console's mix of recordings can run at
require_relative "console/description" # what a game can tell about a console: its screen, buttons, sprites
require_relative "console/variant" # hardware some copies of a console have: a cartridge chip, a model
require_relative "console/gbc_hardware" # the Game Boy Color's register addresses, flags and memory map
require_relative "console/snes_hardware" # the Super Nintendo's register addresses, flags and memory map
require_relative "console/questions" # what a line of a game asks of the console it runs on
require_relative "console/answers" # what an answer to "what does this verb do here?" is
require_relative "console/advance_answers" # ...the Game Boy Advance's: every verb works
require_relative "console/color_answers" # ...and the Game Boy Color's: works or refused
require_relative "console/snes_answers" # ...and the Super Nintendo's: works or refused
require_relative "console/kit" # ...and which parts of the library serve each console
