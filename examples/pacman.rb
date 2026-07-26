#!/usr/bin/env ruby
# frozen_string_literal: true

# Pac-Man — steer a little Pac-Man around with the D-pad, and he turns to face the
# way he's going: mouth to the right when you go right, up when you go up. Run him
# into the pellet to eat it: it pops up somewhere new and your count ticks up.
#
# Two things this shows off. First, facing: Pac-Man is a `sprite` given a set of
# POSES — one image per direction — via `facing:`, so `pac.move :left` both slides
# him left AND turns him to face left in one call. Second, collision: because both
# Pac-Man and the pellet are sprites, each already knows its own on-screen
# rectangle, so `pac.overlaps?(pellet)` asks "are they touching?" with no boxes or
# coordinate math at all — that's the payoff of leaning into sprites. Neither needs
# `blit` or a screen clear per frame: they're sprites, so they repaint themselves
# and leave no trail.
#
# (The four Pac-Man poses are generated here, not hand-drawn: a yellow circle with a
# wedge — the mouth — bitten out on the side he faces. This is pose-swap facing;
# turning to an arbitrary angle would need the console's affine hardware, a
# different feature.)
#
# Run it to build examples/pacman.gba:
#   ruby examples/pacman.rb

require_relative "../lib/ruby_gba"

module Pacman
  SCREEN_W    = 240
  SCREEN_H    = 160
  SPEED       = 2
  SIZE        = 11          # an 11x11 Pac-Man
  R           = SIZE / 2    # radius (and the centre offset)
  PELLET_SIZE = 5
  DIRS        = %i[right left up down].freeze

  # A little round pellet, as ASCII art (transparent corners so it reads as a dot).
  PELLET_ART = <<~ART
    .###.
    #####
    #####
    #####
    .###.
  ART

  # Pac-Man facing +dir+, as ASCII art: '#' is a lit (yellow) body pixel, '.' is
  # transparent. He's the disc of radius R with a triangular wedge — the mouth —
  # bitten out on the side he faces, so the field shows through it.
  def self.pacman_art(dir)
    (0...SIZE).map do |y|
      (0...SIZE).map do |x|
        dx = x - R
        dy = y - R
        in_disc = (dx * dx) + (dy * dy) <= R * R
        in_disc && !in_mouth?(dx, dy, dir) ? "#" : "."
      end.join
    end.join("\n")
  end

  # The mouth is a right-angle wedge opening toward +dir+ from the centre.
  def self.in_mouth?(dx, dy, dir)
    case dir
    when :right then dx.positive? && dx > dy.abs
    when :left  then dx.negative? && -dx > dy.abs
    when :up    then dy.negative? && -dy > dx.abs
    when :down  then dy.positive? && dy > dx.abs
    end
  end

  # The game as a block the builder runs, so a test can drive the exact program
  # that ships — the headless interpreter runs THIS, the console runs the ROM.
  GAME = proc do
    screen :bitmap
    enable_sound
    define_sound :waka, frequency: 660, duty: :half, decay: :fast

    # One yellow pose per direction, generated above, plus the pellet.
    DIRS.each do |dir|
      image(:"pac_#{dir}", "." => :transparent, "#" => :yellow) { Pacman.pacman_art(dir) }
    end
    image(:pellet, "." => :transparent, "#" => :white) { PELLET_ART }

    # Paint the field once; from here Pac-Man and the pellet are sprites that redraw
    # themselves. Seed the stream so each eaten pellet reappears somewhere new.
    clear_screen :black
    seed 1

    # Pac-Man is created first, so he owns the first sprite slot; the pellet follows.
    pac = sprite :pac, at: [(SCREEN_W - SIZE) / 2, (SCREEN_H - SIZE) / 2],
                 facing: { right: :pac_right, left: :pac_left, up: :pac_up, down: :pac_down }
    pellet = sprite :pellet, at: [(SCREEN_W - SIZE) / 2 + SIZE + 8, (SCREEN_H - SIZE) / 2]
    eaten  = var :eaten, 0 # how many pellets Pac-Man has swallowed

    game_loop do
      wait_vblank # the framework repaints the sprites here, in the safe window

      # Hold a direction: he moves that way AND turns to face it — one call each.
      held(:left).then  { pac.move :left,  by: SPEED }
      held(:right).then { pac.move :right, by: SPEED }
      held(:up).then    { pac.move :up,    by: SPEED }
      held(:down).then  { pac.move :down,  by: SPEED }

      # Keep him fully on screen.
      pac.x.clamp(0, SCREEN_W - SIZE)
      pac.y.clamp(0, SCREEN_H - SIZE)

      # Eat the pellet. Both are sprites, so each knows its own rectangle — no boxes,
      # no coordinate math: just ask whether they overlap. On a bite, count it, waka,
      # and drop a fresh pellet somewhere else (it erases and redraws itself).
      pac.overlaps?(pellet).then do
        eaten.add 1
        beep :waka
        pellet.move_to rand(0..(SCREEN_W - PELLET_SIZE)), rand(0..(SCREEN_H - PELLET_SIZE))
      end
    end
  end

  def self.build_rom
    RubyGBA.build("PACMAN", code: "BPAC", maker: "01", &GAME)
  end

  def self.program
    builder = RubyGBA::Builder.new
    builder.instance_eval(&GAME)
    builder.emit_pending_functions
    builder.program
  end
end

if __FILE__ == $PROGRAM_NAME
  rom = Pacman.build_rom
  output = File.join(__dir__, "pacman.gba")
  rom.write(output)
  puts "Built pacman.gba (#{rom.size} bytes)"

  # Set EXPLAIN=1 to print the per-frame draw/sound-cost breakdown for the ROM.
  rom.explain if ENV["EXPLAIN"]
end
