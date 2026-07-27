#!/usr/bin/env ruby
# frozen_string_literal: true

# Animate — a spinning coin you can walk around the field with the D-pad.
#
# A flipbook sprite: you give `sprite` a list of same-size pictures via `frames:`
# and a `rate:`, and the framework cycles through them for you — one picture every
# `rate` frames — with the timer hidden and managed. Nothing to tick, nothing to
# reset. Here the coin's four frames are it seen face-on, half-turned, edge-on, and
# half-turned again, so cycling them reads as a spin.
#
# It composes with everything else: the coin animates AND moves at the same time,
# because `frames:` only drives which picture shows — you still steer it with `move`
# exactly like any other sprite. (Facing and frames are two ways to drive the same
# pose, so a sprite takes one or the other.)
#
# The four frames are generated, not hand-drawn: a gold disc squashed horizontally
# by a different amount each frame, so it looks like a coin turning edge-on and back.
#
# Run it to build examples/animate.gba:
#   ruby examples/animate.rb

require_relative "../lib/ruby_gba"

module Animate
  SIZE  = 16 # a 16x16 coin
  SPEED = 2
  # How wide the coin is on each frame (1.0 = face-on, small = edge-on): face,
  # half-turned, edge-on, half-turned. Cycling these reads as a spin.
  SPIN = [1.0, 0.55, 0.18, 0.55].freeze

  # The coin on frame +k+, as ASCII art: a gold disc squashed horizontally to
  # SPIN[k] of its width, so frame 2 is a thin edge-on sliver.
  def self.coin_art(k)
    half = (SIZE - 1) / 2.0
    rx = half * SPIN[k]
    (0...SIZE).map do |y|
      (0...SIZE).map do |x|
        dx = x - half
        dy = y - half
        (((dx / rx)**2) + ((dy / half)**2)) <= 1.0 ? "Y" : "."
      end.join
    end.join("\n")
  end

  FRAMES = SPIN.each_index.map { |k| :"coin#{k}" }.freeze

  GAME = proc do
    screen :bitmap
    clear_screen rgb(0, 0, 8) # a dark blue field

    SPIN.each_index { |k| image(:"coin#{k}", "." => :transparent, "Y" => :yellow) { Animate.coin_art(k) } }

    # One `sprite` call makes it spin: `frames:` are the pictures to cycle, `rate:` is
    # how many frames each one is shown. The spinning is automatic from here.
    coin = sprite :coin, at: [(240 - SIZE) / 2, (160 - SIZE) / 2], frames: FRAMES, rate: 6

    game_loop do
      wait_vblank # the framework repaints the coin and advances its spin here

      # Steer it while it spins — animation and movement are independent.
      held(:left).then  { coin.move :left,  by: SPEED }
      held(:right).then { coin.move :right, by: SPEED }
      held(:up).then    { coin.move :up,    by: SPEED }
      held(:down).then  { coin.move :down,  by: SPEED }
      coin.x.clamp 0, 240 - SIZE
      coin.y.clamp 0, 160 - SIZE
    end
  end

  def self.build_rom(out: $stdout, err: $stderr)
    RubyGBA.build("ANIMATE", code: "BANM", maker: "01", out: out, err: err, &GAME)
  end

  def self.program
    builder = RubyGBA::Builder.new
    builder.instance_eval(&GAME)
    builder.emit_pending_functions
    builder.program
  end
end

if __FILE__ == $PROGRAM_NAME
  rom = Animate.build_rom
  output = File.join(__dir__, "animate.gba")
  rom.write(output)
  puts "Built animate.gba (#{rom.size} bytes)"
end
