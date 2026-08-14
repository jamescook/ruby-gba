# frozen_string_literal: true

module RubyGBA
  module IR
    # HOW MANY FRAMES A PASS OF THE GAME LOOP TOOK, as a contract every backend keeps.
    #
    # A game loop waits for the screen, does its work, and comes round again. While the work fits
    # in the time between two frames, one pass IS one frame and nothing has to be counted. When
    # the work does not fit, a pass spans two frames or three — and anything that was counting
    # passes and calling them frames is counting the wrong thing.
    #
    # The names live here rather than in a backend because the question is not about any one
    # machine. A target that shows frames can answer it; how it knows is its own business (one
    # reads the screen's own interrupt, another simply knows it is never late).
    module Frames
      # Frames since the program started.
      COUNT = :__frames

      # What that was at the top of the last pass, and the difference between then and now — how
      # many frames the pass that just ended has to answer for. One, on a program that keeps up.
      SEEN = :__frames_seen
      STEP = :__frame_step

      # THE MOST A SINGLE PASS MAY ANSWER FOR. A pass that took half a second is a loading
      # screen, a first frame, or a hitch — and whatever reads this would then be asked to do
      # thirty frames of catching up inside one already-late pass, which is how a slow program
      # talks itself into being a stopped one.
      #
      # Capped HERE and not in each thing that reads it, which is the whole point of the cap
      # living with the number. Ten is the original Wolfenstein's own limit (MAXTICS) and it is a
      # sixth of a second — long enough that no ordinary pass reaches it.
      MOST = 10
    end
  end
end
