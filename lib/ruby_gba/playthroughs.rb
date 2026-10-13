# frozen_string_literal: true

# PLAYING A FINISHED CARTRIDGE WITH NOBODY AT THE CONTROLS: from a script that says what to
# press or a tape of the presses that were made, and two cartridges side by side to find the
# frame where they stop matching.
#
# It plays on the reader over a running cartridge, which is Diagnostics' (the Verifier). The
# line between the two is which way each one faces: Diagnostics reads a cartridge back, and
# what is here drives one.
require_relative "playthroughs/playthrough" # a game driven from a script
require_relative "playthroughs/tape" # ...and the presses it made, written down to play again
require_relative "playthroughs/playthrough_picture_folder" # ...and the folder its pictures are written into
require_relative "playthroughs/comparison" # two cartridges played side by side on the same presses
require_relative "playthroughs/comparison_ignored_frames" # ...and the stretches of the playing it does not look at
require_relative "playthroughs/comparison_readings" # ...and the numbers it reads off both and compares by name
require_relative "playthroughs/comparison_compared" # ...and the list of what it compares: the picture, the readings
require_relative "playthroughs/comparison_at_moments" # ...and the other way to compare: the same script on each
require_relative "playthroughs/comparison_report" # ...and the folder it writes for a drift it finds
require_relative "playthroughs/comparison_drift_report" # ......of a drift on a frame, on the same tape
require_relative "playthroughs/comparison_moment_report" # ......and of a drift at a moment, on the same script
require_relative "playthroughs/command_line" # what `ruby-gba play` and `ruby-gba compare` do with their options
