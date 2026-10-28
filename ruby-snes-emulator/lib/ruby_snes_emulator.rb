# frozen_string_literal: true

# A headless Super Nintendo for checking cartridges from Ruby: bsnes, built as a libretro core
# with a small patch that hands over the console's memories, driven through Fiddle. See
# RubySNESEmulator::Core for what it plays and reads, and RubySNESEmulator::CoreLibrary for
# where the core comes from.
require_relative "ruby_snes_emulator/version"
require_relative "ruby_snes_emulator/core_library"
require_relative "ruby_snes_emulator/core"
