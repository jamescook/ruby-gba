#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates a GBA ROM that displays colored pixels and rectangles.
# Load in any GBA emulator (mGBA, gemba, etc.) to see the output.
#
# Usage:
#   ruby examples/pixels.rb
#
# Output:
#   examples/pixels.gba

require_relative "../lib/ruby_gba"

rom = RubyGBA.build("RUBYGBA", code: "BRBY", maker: "01") do
  display :bitmap

  # Draw an Italian flag in the center of the screen
  flag_x = 70
  flag_y = 50
  stripe_w = 33
  flag_h = 60

  fill_rect flag_x,                flag_y, stripe_w, flag_h, rgb(0, 31, 0)   # green
  fill_rect flag_x + stripe_w,     flag_y, stripe_w, flag_h, :white          # white
  fill_rect flag_x + stripe_w * 2, flag_y, stripe_w, flag_h, :red            # red

  # RGB dots below the flag
  dot_y = 120
  pixel 105, dot_y, :red
  pixel 106, dot_y, :red
  pixel 107, dot_y, :red

  pixel 115, dot_y, :green
  pixel 116, dot_y, :green
  pixel 117, dot_y, :green

  pixel 125, dot_y, :blue
  pixel 126, dot_y, :blue
  pixel 127, dot_y, :blue

  # Corner markers
  fill_rect 0, 0, 4, 4, :yellow              # top-left
  fill_rect 236, 0, 4, 4, :cyan              # top-right
  fill_rect 0, 156, 4, 4, :magenta           # bottom-left
  fill_rect 236, 156, 4, 4, color("#FF8800") # bottom-right (orange via hex)

  halt
end

out = File.join(__dir__, "pixels.gba")
rom.write(out)
puts "Wrote #{rom.size} bytes to #{out}"

# Report how much drawing this ROM does — a heads-up on whether it fits the
# console's per-frame drawing window. (Not every example prints this; it's shown
# here to demonstrate the estimator.)
rom.explain
