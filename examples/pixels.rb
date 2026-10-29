#!/usr/bin/env ruby
# frozen_string_literal: true

# Draws colored pixels and rectangles on a painted screen: a flag in the middle, three dots
# under it, and a marker in each corner.
#
# Everything is placed from the screen's own size (`screen_width`, `screen_height`), so the
# same picture comes out right on the Game Boy Advance's 240x160 screen and the Super
# Nintendo's 256x224: the flag stays in the middle and the markers stay in the corners.
#
# Usage:
#   ruby examples/pixels.rb
#
# Output:
#   examples/pixels.gba and examples/pixels.sfc

require_relative "../lib/vblank"

Pixels = VBlank.game("RUBYGBA", consoles: %i[gba snes]) do
  screen :bitmap

  # Draw an Italian flag in the center of the screen
  stripe_w = 33
  flag_h = 60
  flag_x = (screen_width - (stripe_w * 3)) / 2
  flag_y = (screen_height - flag_h) / 2

  fill_rect flag_x,                flag_y, stripe_w, flag_h, rgb(0, 31, 0)   # green
  fill_rect flag_x + stripe_w,     flag_y, stripe_w, flag_h, :white          # white
  fill_rect flag_x + stripe_w * 2, flag_y, stripe_w, flag_h, :red            # red

  # RGB dots below the flag
  dot_x = flag_x + 35
  dot_y = flag_y + flag_h + 10
  pixel dot_x,      dot_y, :red
  pixel dot_x + 1,  dot_y, :red
  pixel dot_x + 2,  dot_y, :red

  pixel dot_x + 10, dot_y, :green
  pixel dot_x + 11, dot_y, :green
  pixel dot_x + 12, dot_y, :green

  pixel dot_x + 20, dot_y, :blue
  pixel dot_x + 21, dot_y, :blue
  pixel dot_x + 22, dot_y, :blue

  # Corner markers
  right = screen_width - 4
  bottom = screen_height - 4
  fill_rect 0, 0, 4, 4, :yellow                   # top-left
  fill_rect right, 0, 4, 4, :cyan                 # top-right
  fill_rect 0, bottom, 4, 4, :magenta             # bottom-left
  fill_rect right, bottom, 4, 4, color("#FF8800") # bottom-right (orange via hex)

  halt
end

Pixels.write_if_main
