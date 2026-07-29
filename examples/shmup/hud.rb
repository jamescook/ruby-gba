# frozen_string_literal: true

# The heads-up display — score and remaining ships — in its own file. It owns the two
# variables and declares the on-screen text (tiled-mode text is a set-and-forget element:
# declared once, it repaints itself from its variable every frame). Declared inside the
# playing scene, the whole HUD belongs to that scene, so it's on screen while you play and
# gone on the game-over screen — nothing here has to know that. The other parts call
# score_up / hit and read `lives`; the numbers follow.
module Shmup
  class Hud
    START_LIVES = 3

    def initialize(build)
      @build = build
      @score = build.var(:score, 0)
      @lives = build.var(:lives, START_LIVES)
      build.draw_text   "SCORE", 8, 4, :white
      build.draw_number :score, 46, 4, :yellow, digits: 4
      build.draw_text   "SHIPS", 152, 4, :white
      build.draw_number :lives, 194, 4, :yellow, digits: 1
    end

    # How many ships are left — the main file watches this to end the game.
    attr_reader :lives

    def score_up
      @score.add 10
    end

    def hit
      @lives.sub 1
      @lives.clamp 0, 9 # keep the display sane if two enemies land on the same frame
    end

    # Back to a fresh game.
    def reset
      @score.set 0
      @lives.set START_LIVES
    end
  end
end
