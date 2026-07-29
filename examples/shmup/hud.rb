# frozen_string_literal: true

# The heads-up display — score and remaining ships — in its own file. It owns the two
# variables and declares the on-screen text once (tiled-mode text is a set-and-forget
# element: declared before the game loop, it repaints itself from its variable every
# frame). The other parts don't touch the text or the variables; they call score_up /
# hit, and the numbers follow. No per-frame `update` here — there's nothing to do each
# frame, so it just exposes the events it reacts to.
module Shmup
  class Hud
    def initialize(build)
      @build = build
      @score = build.var(:score, 0)
      @lives = build.var(:lives, 3)
      build.draw_text   "SCORE", 8, 4, :white
      build.draw_number :score, 46, 4, :yellow, digits: 4
      build.draw_text   "SHIPS", 152, 4, :white
      build.draw_number :lives, 194, 4, :yellow, digits: 1
    end

    def score_up
      @score.add 10
    end

    def hit
      @lives.sub 1
      @lives.clamp 0, 9 # don't run negative (no game-over screen in this first cut)
    end
  end
end
