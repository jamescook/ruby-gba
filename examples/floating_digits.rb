#!/usr/bin/env ruby
# frozen_string_literal: true

# Floating digits — the numbers 0 through 9 drift around the screen and bounce off
# the walls, each in its own solid color.
#
# It's also a little study in "moving text". A number that STAYS PUT and only
# changes value (a score, a timer) is what draw_number is for. But a number whose
# POSITION moves is a different job: it has to be picked up and set down each frame
# without smearing a trail — the same problem a moving sprite has. draw_text and
# draw_number draw at a FIXED spot, so they can't move; the one draw verb with a
# run-time position is `blit`. So each digit here is a tiny glyph image (drawn from
# the built-in font) that we blit at a moving position — a moving object, built by
# hand. When the `sprite` helper lands, this whole file collapses to "make a sprite
# for each digit and nudge it"; for now it's the honest manual version.
#
# Run it to build examples/floating_digits.gba:
#   ruby examples/floating_digits.rb

require_relative "../lib/ruby_gba"

module FloatingDigits
  SCREEN_W = 240
  SCREEN_H = 160
  W = RubyGBA::Fonts.default.width  # 5px wide glyph
  H = RubyGBA::Fonts.default.height # 7px tall glyph

  # One solid color per digit (5-bit R,G,B channels, 0..31), all clearly distinct.
  COLORS = [
    [31,  0,  0], [0, 31,  0], [8, 12, 31], [31, 31,  0], [0, 31, 31],
    [31,  0, 31], [31, 31, 31], [31, 18,  0], [18, 31,  0], [0, 18, 31],
  ].freeze

  # The glyph for digit +d+ as ASCII art ('#' = a lit pixel, '.' = transparent),
  # read straight from the built-in bitmap font — so we don't hand-draw ten digits.
  def self.glyph_art(d)
    lit = {}
    RubyGBA::Fonts.default.each_pixel(d.to_s) { |x, y| lit[[x, y]] = true }
    (0...H).map { |y| (0...W).map { |x| lit[[x, y]] ? "#" : "." }.join }.join("\n")
  end

  # The game as a block the builder runs (so a test can drive the exact program
  # that ships — the interpreter runs THIS, the console runs the ROM built from it).
  GAME = proc do
    screen :bitmap

    # A colored glyph image per digit. '.' is transparent, so only the digit's lit
    # pixels are drawn and the black field shows through the rest of the 5x7 box.
    10.times do |d|
      image(:"digit#{d}", "." => :transparent, "#" => rgb(*COLORS[d])) { FloatingDigits.glyph_art(d) }
    end

    # Each digit gets a position and a velocity. They start spread across the
    # screen, each drifting a little differently.
    movers = 10.times.map do |d|
      {
        d: d,
        x:  var(:"x#{d}",  10 + (d % 5) * 44),
        y:  var(:"y#{d}",  22 + (d / 5) * 74),
        dx: var(:"dx#{d}", [2, -2, 1, -1, 2][d % 5]),
        dy: var(:"dy#{d}", [1, 2, -1, -2, 1][(d + 2) % 5]),
      }
    end

    max_x = SCREEN_W - W # rightmost x that keeps the whole glyph on screen
    max_y = SCREEN_H - H

    game_loop do
      wait_vblank
      # The simple, unclever way: wipe the screen and redraw every digit. It's a
      # touch wasteful (a real game would erase only where each digit was), but at
      # this scale it fits the frame comfortably and keeps the example plain.
      clear_screen :black

      movers.each do |m|
        x = m[:x]
        y = m[:y]
        dx = m[:dx]
        dy = m[:dy]

        x.add dx
        y.add dy

        # Bounce off each wall: pin the digit to the edge and reverse its direction.
        (x < 0).then     { x.set 0;     dx.flip }
        (x > max_x).then { x.set max_x; dx.flip }
        (y < 0).then     { y.set 0;     dy.flip }
        (y > max_y).then { y.set max_y; dy.flip }

        blit :"digit#{m[:d]}", :"x#{m[:d]}", :"y#{m[:d]}"
      end
    end
  end

  def self.build_rom
    RubyGBA.build("FLOATNUM", code: "BFLN", maker: "01", &GAME)
  end

  # The IR program on its own — what the headless interpreter runs in tests.
  def self.program
    builder = RubyGBA::Builder.new
    builder.instance_eval(&GAME)
    builder.emit_pending_functions
    builder.program
  end
end

if __FILE__ == $PROGRAM_NAME
  rom = FloatingDigits.build_rom
  output = File.join(__dir__, "floating_digits.gba")
  rom.write(output)
  puts "Built floating_digits.gba (#{rom.size} bytes)"

  # Set EXPLAIN=1 to print the per-frame draw/sound-cost breakdown for the ROM —
  # where the frame's work goes, and whether it fits the budget the console has to
  # change the screen without tearing.
  rom.explain if ENV["EXPLAIN"]
end
