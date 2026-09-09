#!/usr/bin/env ruby
# frozen_string_literal: true

# Sparks — a shower of particles: a fixed handful of slots, one spark spawned a frame at a
# random column, each falling until it leaves the bottom and hands its slot back.
#
# It shows what `pool` is for, and it is the shape a bullet, enemy or particle game spends
# its frame in: many of one thing, each with a few fields, walked every frame. The walk is
# over every slot the pool has; the body runs only for the live ones, and a spark that has
# fallen off the bottom removes itself, so a slot never leaks. On a bitmap screen a pool
# draws nothing on its own, so the body draws each spark as a two-pixel dot.
#
# Run it to build examples/sparks.gba:
#   ruby examples/sparks.rb

require_relative "../lib/ruby_gba"

module Sparks
  SLOTS = 32 # sparks alive at once; a full pool recycles its oldest
  USUAL = 20 # about how many are falling on a normal frame, for the cost report

  # The game as a block the builder runs, so a test can drive the exact program that
  # ships — the headless interpreter runs THIS, the console runs the ROM.
  GAME = RubyGBA.game("SPARKS", code: "BSPK", maker: "01") do
    screen :bitmap
    seed 0x5EED # a fixed stream, so every run is the same run

    sparks = pool(:spark, x: 0, y: 0, vy: 0, capacity: SLOTS, on_full: :recycle_oldest,
                          estimate: { usually: USUAL }, widths: { vy: :byte })

    game_loop do
      clear_screen :black
      # One new spark a frame, at a random column, falling at one of three speeds.
      sparks.spawn(x: rand(0..238), y: 0, vy: rand(1..3))
      sparks.each do |s|
        s.y.add s.vy
        draw_rect_at s.x, s.y, 2, 2, :yellow
        (s.y >= 160).then { s.remove } # off the bottom: give the slot back
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Sparks::GAME.write_if_main
