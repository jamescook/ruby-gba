# frozen_string_literal: true

# READING A BUILT OR RUNNING CARTRIDGE BACK: taking a finished ROM apart, running one and
# looking at the pixels and the sound it really produced, and measuring where its frames went.
# All of it needs a cartridge to exist first — what a build says while there is not one yet is
# Messages.

require_relative "diagnostics/sprite_row" # one sprite read back, off the console or off the oracle
require_relative "diagnostics/video_memory" # how much room the pictures took, and what the storage saved
require_relative "diagnostics/inspector" # a finished ROM taken apart: header, and the code disassembled
require_relative "diagnostics/func_dumper"
require_relative "diagnostics/emulator" # the one seam to the emulator backend; swap emulators here
require_relative "diagnostics/verifier" # ...and reading real pixels and real sound back through it
require_relative "diagnostics/tearing"
require_relative "diagnostics/flicker"
require_relative "diagnostics/tick_rate"
require_relative "diagnostics/sound_drops"
require_relative "diagnostics/analyzer"
require_relative "diagnostics/build_report" # the exact half of a profile: what the build made
require_relative "diagnostics/profiler" # ...and the measured half: where the frames went
require_relative "diagnostics/routine_profile"
