#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate examples/assets/pacman_sheet.png from the pacman_art formula in
# examples/pacman.rb. This is the "author the art" step: it bakes the disc-and-mouth
# formula into a real sprite sheet, which pacman.rb then imports with `facing_from:` —
# the way a game brings in art from a file. Re-run it whenever you change the formula:
#
#   ruby examples/assets/gen_pacman_sheet.rb
#
# The sheet is the grid `sprite facing_from:` expects: one ROW per direction (in the
# order below, top to bottom) and two COLUMNS — mouth open, then mouth shut. Needs
# ImageMagick (the `magick` command) to write the PNG, the same tool the importer reads
# it back with.

require_relative "../../lib/ruby_gba"
require_relative "../pacman"

DIRS   = Pacman::DIRS          # one row each: right, left, up, down
FRAMES = [true, false].freeze  # two columns: mouth open, then shut
SIZE   = Pacman::SIZE

# The 8-bit RGB that imports back to exactly the framework's :yellow, so Pac's body is
# the same yellow whether drawn from the formula or from the sheet. The color is a
# 15-bit BGR555 value; spread each 5-bit channel across the full 8-bit range.
def yellow_rgb
  v = RubyGBA::Color.resolve(:yellow)
  [0, 5, 10].map do |shift|
    c = (v >> shift) & 0x1F
    (c << 3) | (c >> 2)
  end
end

YELLOW = yellow_rgb

# Every cell's art, computed once: cells[row][col] is an array of SIZE strings.
cells = DIRS.map { |dir| FRAMES.map { |open| Pacman.pacman_art(dir, open: open).split("\n") } }

width  = FRAMES.length * SIZE
height = DIRS.length * SIZE

# Pack the whole sheet as raw RGBA, row by row (top to bottom, left to right). A body
# pixel ('Y') is opaque yellow; everything else is fully transparent, so the cut-out
# background shows through when `facing_from: ..., transparent: true` imports it.
bytes = (+"").b
height.times do |y|
  row = y / SIZE
  cy  = y % SIZE
  width.times do |x|
    col = x / SIZE
    cx  = x % SIZE
    if cells[row][col][cy][cx] == "Y"
      bytes << YELLOW[0].chr << YELLOW[1].chr << YELLOW[2].chr << 255.chr
    else
      bytes << 0.chr << 0.chr << 0.chr << 0.chr
    end
  end
end

out = File.join(__dir__, "pacman_sheet.png")
IO.popen(["magick", "-size", "#{width}x#{height}", "-depth", "8", "rgba:-", out], "wb") do |io|
  io.write(bytes)
end
puts "Wrote #{out} (#{width}x#{height}: #{FRAMES.length} cols x #{DIRS.length} rows of #{SIZE}px)"
