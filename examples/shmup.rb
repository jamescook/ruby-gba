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
#   examples/shmup/player.rb   — the ship and its shot (move, fire, a moment it cannot be hit)
#   examples/shmup/enemies.rb  — a fixed few enemies that dive and respawn
#   examples/shmup/boss.rb     — a 96x48 cruiser: one sprite, bigger than the console draws
#   examples/shmup/hud.rb      — the score / ships display
#
# The game is two scenes: PLAYING and a GAME OVER screen. A scene owns what it draws — the
# ship, enemies, boss and HUD are declared inside the playing scene, so they're on screen
# while you play and gone on the game-over screen, with nothing to hide by hand. Losing the
# last ship switches scenes; START on the game-over screen starts a fresh game.
#
# A wave of enemies in, the boss turns up: a cruiser wider than any picture the console can
# draw in one go, written as one `sprite` at the size it was drawn. Run it to build
# examples/shmup.gba:
#   ruby examples/shmup.rb

require_relative "../lib/ruby_gba"
require_relative "shmup/player"
require_relative "shmup/enemies"
require_relative "shmup/boss"
require_relative "shmup/hud"

module Shmup
  PLAYING = 0
  GAME_OVER = 1

  # A warm pulse, four steps long, for anything that has just been hit: the ship while it
  # cannot be hit again, the boss for a moment after each shot lands. Each is a list of
  # colours laid out like a picture's own `colors:` list, and a sprite drawn with one keeps
  # its shape and shading while its colours step through these. The fourth is the second
  # again, so the pulse rises and falls; the two share their colours on the console too.
  WARM = %i[warm_yellow warm_orange warm_red warm_orange_again].freeze

  GAME = RubyGBA.game("SHMUP", code: "BSMP", maker: "01") do
    screen :tiled
    # The stack, back to front — one line saying what is in front of what, for a picture
    # whose parts are declared in three different files. The fade below then sits UNDER
    # :ui, so it reaches the field and everything moving in it and leaves the score alone.
    layers :enemies, :ship, :ui
    seed 0xC0DE # a fixed stream once at boot, so enemy respawns are reproducible
    # Place for place: see-through, the hull, then the bright part (the cockpit, the core).
    colors :warm_yellow,       [:transparent, :yellow, :white]
    colors :warm_orange,       [:transparent, :orange, :yellow]
    colors :warm_red,          [:transparent, :red, :orange]
    colors :warm_orange_again, [:transparent, :orange, :yellow]
    var :state, PLAYING
    new_game = var :new_game, 0 # 1 asks the playing scene to start over
    leaving  = var :leaving, 0  # 1 while the field dims on the way to the game-over screen

    # The playing scene owns the whole field — declaring the parts here makes their
    # sprites and HUD belong to this scene, so they vanish on the game-over screen.
    scene :playing do
      enemies = layer(:enemies) { Enemies.new(self) }
      player  = layer(:ship)    { Player.new(self) }
      hud     = layer(:ui)      { Hud.new(self) }
      # The boss goes in the same layer as the enemies, so the ship flies in front of it.
      # It takes the ship and the HUD up front because it shoots at one and scores on the
      # other, and its behaviour is `func`s declared once rather than a per-frame block.
      boss = layer(:enemies) { Boss.new(self, player, hud) }

      # Start a fresh game when the game-over screen asked for one: everything back to
      # its opening position, then clear the request.
      (new_game == 1).then do
        player.reset
        enemies.reset
        boss.reset
        hud.reset
        set :new_game, 0
      end

      player.update
      enemies.update(player, hud)
      boss.update

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
      draw_text "GAME OVER",   :center, 68, :red
      draw_text "PRESS START", :center, 88, :white
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
