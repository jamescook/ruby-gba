# frozen_string_literal: true

# A GAME PLAYED LIVE BY THE INTERPRETER: Ruby itself runs the game a pass at a time while a
# person watches and plays, its picture put on a screen, its buttons read from a keyboard or a
# pad. Every other way to play a game has this loop already, in its own language — the
# console's hardware, the C build's desktop program, the web page's script — and the
# interpreter is the one whose loop has to be written in Ruby.
#
# The playing is the session's; what it is shown on is a device, which shows a picture, says
# which buttons are held and whether to stop, and keeps the time. The headless device is the
# one with no screen, for a test or a measurement.
#
# It is not part of `require "vblank"`, the way vblank/testing is not: the screen device, still
# to come, reaches its window through Fiddle, which a game that only builds cartridges never
# needs.
require_relative "../vblank"
require_relative "live/rate" # how fast the play went: passes and frames a second
require_relative "live/session" # the game played a pass at a time through a device
require_relative "live/headless" # ...a device with no screen, whose clock a test moves
