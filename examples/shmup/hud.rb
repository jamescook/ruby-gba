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

    SCREEN_W = 240
    ROW      = 4  # the row the whole bar sits on
    MARGIN   = 8  # how far in from each edge of the screen the bar starts
    GAP      = 6  # between a label and its figures

    def initialize(build)
      @build = build
      @score = build.var(:score, 0)
      @lives = build.var(:lives, START_LIVES)
      # The score pair starts at the left margin and its figures hang one gap off the
      # end of the word, so rewording a label moves its number with it. The ships pair
      # is the same thing flush against the other edge: the figure takes the last
      # column, and the word is pushed up against the gap in front of it. No column
      # here is a number counted by eye.
      build.draw_text   "SCORE", MARGIN, ROW, :white
      build.draw_number :score, MARGIN + build.text_width("SCORE") + GAP, ROW, :yellow, digits: 4
      build.draw_number :lives, :right, ROW, :yellow, digits: 1, within: 0...(SCREEN_W - MARGIN)
      build.draw_text   "SHIPS", :right, ROW, :white,
                        within: 0...(SCREEN_W - MARGIN - build.text_width("0") - GAP)
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
