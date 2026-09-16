# frozen_string_literal: true

# WHAT A CHECKED PROGRAM BECOMES: the bytes on the card, and everything about the card itself —
# the header, the four characters an emulator tells one cartridge from another by, the checks a
# finished one has to pass. The machine code inside it is the lowering's business, not this
# module's (see IR::Backends::GBA).

require_relative "cartridge/constants" # the hardware's register addresses and flags
require_relative "cartridge/rom_validator"
require_relative "cartridge/build_record" # what the build worked out, for the cartridge to carry
require_relative "cartridge/game_code" # the four characters an emulator tells one cartridge from another by
require_relative "cartridge/rom"
require_relative "cartridge/evaluated_game" # the one place a game's block becomes a program
require_relative "cartridge/game"
require_relative "cartridge/test_patterns"
