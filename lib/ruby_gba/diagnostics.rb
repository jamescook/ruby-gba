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
require_relative "diagnostics/full_collections" # every list and pool, and how to hold each one full
require_relative "diagnostics/profiler" # ...and the measured half: where the frames went
require_relative "diagnostics/routine_profile"
require_relative "diagnostics/cartridge_file" # a cartridge that is only its file, with no record of its build
require_relative "diagnostics/save_bytes" # ...and a save of a kind the framework has no model of, kept as its bytes
require_relative "diagnostics/playthrough" # a game driven with nobody at the controls, from a script
require_relative "diagnostics/playthrough_tape" # ...and the presses it made, written down to play again
require_relative "diagnostics/playthrough_picture_folder" # ...and the folder its pictures are written into
require_relative "diagnostics/comparison" # two cartridges played side by side on the same presses
require_relative "diagnostics/comparison_ignored_frames" # ...and the stretches of the playing it does not look at
require_relative "diagnostics/comparison_drift_report" # ...and the folder it writes for a drift it finds
