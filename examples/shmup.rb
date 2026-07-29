#!/usr/bin/env ruby
# frozen_string_literal: true

# Shmup — a whole game split across files, with real scenes.
#
# A game outgrows a single `RubyGBA.build` block. The way out is plain Ruby: each part of
# the game is an ordinary object in its own file that takes the build (the object
# `RubyGBA.build` hands your block as `self`) and calls the DSL verbs on it — build.sprite,
# build.held, build.var — the same verbs you'd write inline. There's no base class and no
# magic: pass the build in, call verbs on it.
#
#   examples/shmup/player.rb   — the ship and its shot (move, fire)
#   examples/shmup/enemies.rb  — a fixed few enemies that dive and respawn
#   examples/shmup/hud.rb      — the score / ships display
#
# The game is two scenes: PLAYING and a GAME OVER screen. A scene owns what it draws — the
# ship, enemies, and HUD are declared inside the playing scene, so they're on screen while
# you play and gone on the game-over screen, with nothing to hide by hand. Losing the last
# ship switches scenes; START on the game-over screen starts a fresh game. Run it to build
# examples/shmup.gba:
#   ruby examples/shmup.rb

require_relative "../lib/ruby_gba"
require_relative "shmup/player"
require_relative "shmup/enemies"
require_relative "shmup/hud"

module Shmup
  PLAYING = 0
  GAME_OVER = 1

  GAME = proc do
    screen :tiled
    seed 0xC0DE # a fixed stream once at boot, so enemy respawns are reproducible
    var :state, PLAYING
    new_game = var :new_game, 0 # 1 asks the playing scene to start over

    # The playing scene owns the whole field — declaring the parts here makes their
    # sprites and HUD belong to this scene, so they vanish on the game-over screen.
    scene :playing do
      enemies = Enemies.new(self) # declared first, so they draw behind the ship
      player  = Player.new(self)
      hud     = Hud.new(self)

      # Start a fresh game when the game-over screen asked for one: everything back to
      # its opening position, then clear the request.
      (new_game == 1).then do
        player.reset
        enemies.reset
        hud.reset
        set :new_game, 0
      end

      player.update
      enemies.update(player, hud)

      # Out of ships: hand over to the game-over screen.
      (hud.lives <= 0).then { set :state, GAME_OVER }
    end

    # The game-over screen: its own text, shown only while this scene is active. START
    # begins a fresh game (the playing scene does the resetting).
    scene :game_over do
      draw_text "GAME OVER",   93, 68, :red
      draw_text "PRESS START", 87, 88, :white
      pressed(:start).then do
        set :new_game, 1
        set :state, PLAYING
      end
    end

    game_loop do
      wait_vblank
      case_var :state do
        when_val PLAYING,   :playing
        when_val GAME_OVER, :game_over
      end
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
