#!/usr/bin/env ruby
# frozen_string_literal: true

# Build wolf3d.gba:
#
#   ruby games/wolf3d/wolf3d.rb
#
# Requiring this file (a test does) builds nothing and writes nothing.

require_relative "lib/wolf3d"

Wolf3D.report if $PROGRAM_NAME == __FILE__
Wolf3D::GAME.write_if_main
