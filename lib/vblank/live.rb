# frozen_string_literal: true

# A GAME PLAYED LIVE, IN RUBY: the game built as Ruby (IR::Backends::Ruby) runs in this process a
# pass at a time while a person watches and plays, its picture put on a screen, its buttons read
# from a keyboard or a pad.
#
# The playing is the session's; what it is shown on is a device, which shows a picture, says
# which buttons are held and whether to stop, and keeps the time. The headless device is the
# one with no screen, for a test or a measurement.
#
# It is not part of `require "vblank"`, the way vblank/testing is not: the window (SDL) is reached
# through Fiddle, which a game that only builds cartridges never needs, and Fiddle is loaded only
# when a window is asked for.
require_relative "../vblank"
require_relative "live/rate" # how fast the play went: passes and frames a second
require_relative "live/session" # the game played a pass at a time through a device
require_relative "live/headless" # ...a device with no screen, whose clock a test moves
require_relative "live/menu" # the window's menu: its settings, a line each, with no window of its own
require_relative "live/sdl" # ...and a window, for a person: SDL3 through Fiddle, loaded when a window is asked for
