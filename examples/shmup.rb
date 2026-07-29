#!/usr/bin/env ruby
# frozen_string_literal: true

# Shmup — a whole game split across files.
#
# A game outgrows a single `RubyGBA.build` block. The way out is plain Ruby: each part
# of the game is an ordinary object in its own file that takes the build (the object
# `RubyGBA.build` hands your block as `self`) and calls the DSL verbs on it —
# build.sprite, build.held, build.var — the same verbs you'd write inline, spelled
# `build.` because inside an object `self` is that object, not the build. There's no
# base class and no magic: pass the build in, call verbs on it.
#
# The convention this example follows: a collaborator exposes `update` as its per-frame
# entry point (and any other methods it needs — the player's `reclaim_shot`, the HUD's
# `score_up`). The build block just wires them together and drives them from the loop.
#
#   examples/shmup/player.rb   — the ship and its shot (move, fire)
#   examples/shmup/enemies.rb  — a fixed few enemies that dive and respawn
#   examples/shmup/hud.rb      — the score / ships display
#
# It's a `screen :tiled` game, so it uses everything the tiled path gives you: hardware
# sprites that compose for free, a HUD drawn as text, and per-pixel collision between
# the ship's shot and the enemies. Run it to build examples/shmup.gba:
#   ruby examples/shmup.rb

require_relative "../lib/ruby_gba"
require_relative "shmup/player"
require_relative "shmup/enemies"
require_relative "shmup/hud"

module Shmup
  GAME = proc do
    screen :tiled

    enemies = Enemies.new(self) # declared first, so they draw behind the ship
    player  = Player.new(self)
    hud     = Hud.new(self)     # HUD text: declared once, drawn on top, updates itself

    game_loop do
      wait_vblank
      player.update
      enemies.update(player, hud)
    end
  end

  def self.build_rom(out: $stdout, err: $stderr)
    RubyGBA.build("SHMUP", code: "BSMP", maker: "01", out: out, err: err, &GAME)
  end

  def self.program
    builder = RubyGBA::Builder.new
    builder.instance_eval(&GAME)
    builder.emit_pending_functions
    builder.program
  end
end

if __FILE__ == $PROGRAM_NAME
  rom = Shmup.build_rom
  output = File.join(__dir__, "shmup.gba")
  rom.write(output)
  puts "Built shmup.gba (#{rom.size} bytes)"
end
