#!/usr/bin/env ruby
# frozen_string_literal: true

# Shmup — a whole game split across files, with real scenes.
#
# A game outgrows a single `RubyGBA.game` block. The way out is plain Ruby: each part of
# the game is an ordinary object in its own file that takes the build (the object
# `RubyGBA.game` hands your block as `self`) and calls the DSL verbs on it — build.sprite,
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

  GAME = RubyGBA.game("SHMUP", code: "BSMP", maker: "01") do
    screen :tiled
    # The stack, back to front. Only the HUD names a layer here, and that is enough: the
    # fade below sits UNDER :ui, so it reaches the field and everything that moves in it
    # and leaves the score alone. Anything that named no layer keeps the place it had.
    layers :field, :ui
    seed 0xC0DE # a fixed stream once at boot, so enemy respawns are reproducible
    var :state, PLAYING
    new_game = var :new_game, 0 # 1 asks the playing scene to start over
    leaving  = var :leaving, 0  # 1 while the field dims on the way to the game-over screen

    # The playing scene owns the whole field — declaring the parts here makes their
    # sprites and HUD belong to this scene, so they vanish on the game-over screen.
    scene :playing do
      enemies = Enemies.new(self) # declared first, so they draw behind the ship
      player  = Player.new(self)
      hud     = layer(:ui) { Hud.new(self) } # ...and the score sits above the lot

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

      # Out of ships: dim the field away, and hand over only once it is properly dark.
      #
      # Fading out leaves the screen black on purpose, so anything drawn next is invisible
      # until something lifts it — which means the switch has to WAIT for the fade. That's
      # what reading `fade_level` is for: 0 is the picture as drawn, 100 is nothing but the
      # color, so `== 100` is "it has arrived". Then swap screens while nobody can see it
      # and bring the new one up. The player sees one smooth dip to black and back.
      #
      # `under: :ui` puts the fade below the score, so the field and the ships in it go
      # dark and the numbers stay readable all the way down — the arcade thing where the
      # game disappears and the score you just got does not.
      ((hud.lives <= 0) & (leaving == 0)).then do
        fade_out :black, frames: 12, under: :ui
        leaving.set 1
      end
      (leaving == 1).then do
        (fade_level == 100).then do
          set :state, GAME_OVER
          fade_in frames: 12
          leaving.set 0
        end
      end
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
      case_var :state do
        when_val PLAYING,   :playing
        when_val GAME_OVER, :game_over
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Shmup::GAME.write_if_main
