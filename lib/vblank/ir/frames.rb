# frozen_string_literal: true

module VBlank
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

      # THE STATEMENTS A BEAT MEANS — `every` and `after` (Reference#exec_every, #exec_after) —
      # said as the plain ones every lowering already makes, so none of them writes the rule
      # again. The beat's counter moves on by the frames the pass answers for, and at least one:
      # before the first frame has ended nothing has been counted yet, and that pass is a frame.
      #
      # A repeating beat takes its period off rather than starting again from nought, so one
      # that overshoots keeps the remainder. A one-shot fires when its count is REACHED rather
      # than landed on, because a pass worth two frames can step over the frame it waited for,
      # and stops counting once it has fired, so it never fires twice.
      def self.beat_statements(node)
        frames = Build.clamped(Build.var_ref(STEP), Build.int(1), Build.int(Int32::MAX))
        counter = Build.var_ref(node.counter)
        case node.kind
        when :every
          reached = Build.binop(:>=, counter, Build.int(node.period))
          [Build.add(node.counter, frames), Build.if_(reached, Build.sub(node.counter, node.period), *node.children)]
        when :after
          fires = Build.if_(Build.binop(:>=, counter, Build.int(node.frames)), *node.children)
          [Build.if_(Build.binop(:<, counter, Build.int(node.frames)), Build.add(node.counter, frames), fires)]
        else
          raise ArgumentError, "#{node.kind.inspect} is not a beat"
        end
      end
    end
  end
end
