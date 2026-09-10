# frozen_string_literal: true

module Wolf3D
  # DYING: the view turns to face whatever killed you, and then dots over to red.
  #
  # Read out of the original (wl_game.cpp, Died) rather than remembered. Two things happen and
  # the order is the point. First the view rotates until it is looking straight at the guard who
  # shot you, drawing every step — which is what makes a death read as being killed BY
  # something rather than as the game stopping. Then the view fills with red one pixel at a
  # time, scattered, and closes up.
  #
  # NOTHING ELSE RUNS while either is happening. No walking, no guards, no doors — the world
  # stops the moment you are hit. That is what the original does and it is also what makes this
  # affordable: the eighty rays and eighty stretched columns that a normal frame spends nearly
  # all of itself on are simply not drawn once the fizzle starts, so the whole frame is free for
  # the dots.
  #
  # WHY IT IS NOT A SHIFT REGISTER. The original scatters with a maximum-length linear feedback
  # shift register, which visits every pixel exactly once with nothing to remember — a shift, a
  # test and an exclusive-or per pixel. This framework has no bitwise operators at all (the IR
  # knows + - * / % and the comparisons, and nothing else), so that is not expressible, and
  # adding one is a new IR operator with a conformance fixture, a cost weight and two backends
  # behind it — far more than this needs.
  #
  # What replaces it does the same job with the arithmetic that IS here. Step a number by
  # multiplying it, modulo a prime just above the number of pixels: `n = n * STEP % MODULUS`.
  # With STEP a primitive root, that visits every value from 1 to MODULUS-1 exactly once before
  # it comes back round, which is the same guarantee the shift register gives — every pixel
  # once, nothing remembered but the current number. It is two instructions rather than three,
  # and the six values that overshoot the last pixel fall off the bottom of the view and are
  # clipped, so nothing has to test for them.
  #
  # AND WHY EVERY DOT IS DRAWN TWICE. This game draws on a tear-free screen, which keeps two
  # pictures and shows them in turn — so a frame's drawing lands on one of them and the next
  # frame's on the other. A program that repaints everything every frame never notices. This one
  # ADDS to what is already there, so drawn once, each page would get half the dots and the
  # screen would flicker between two half-finished pictures.
  #
  # `keep_showing` IS THE FRAMEWORK'S ANSWER TO THAT and does not fit here. It paints the same
  # picture again on the next frame, which suits a figure that changed and is then left alone —
  # the status bar, the GAME OVER words. A fizzle draws DIFFERENT dots every frame, so painting
  # it again a frame later draws the next batch rather than this one twice.
  #
  # So there are two walkers stepping the same sequence, one a frame behind the other. Every dot
  # is drawn on two consecutive frames, which is one of each page, and neither walker has to
  # know anything about the other or about which page it is on.
  class Dying
    # What the player is doing. Everything else in the game asks this before it moves.
    ALIVE = 0
    TURNING = 1   # facing whatever killed you
    FIZZLING = 2  # the view dotting over to red
    GONE = 3      # the story is told — what happens next is Lives's business, not this one's

    # The red, out of the game's own 256, which is the one the original fills with.
    INK = 4

    ACROSS = FirstPerson::ACROSS
    DOWN = FirstPerson::VIEW_H
    PIXELS = ACROSS * DOWN

    # THE STEP AND THE PRIME, worked out once and written down rather than computed at build
    # time, because finding a primitive root needs the factors of MODULUS-1 and that is a lot of
    # machinery to carry for two numbers that will never change. What they promise — that
    # stepping from 1 reaches every value below MODULUS exactly once — is checked by a test, by
    # walking the whole sequence, which needs no number theory to read.
    #
    # MODULUS is the first prime above the number of pixels, so six of its values name a spot
    # past the last one. See #scatter for where those six go.
    MODULUS = 30_727
    STEP = 15_363

    # How long the fizzle takes: one second, which is what the original spends on it (70 frames
    # of its 70 a second, so sixty of this console's).
    #
    # COUNTED IN PASSES OF THE GAME LOOP rather than in frames, unlike everything else the game
    # moves by, and on purpose. Drawing belongs to the pass — which page it lands on is decided
    # by the pass, and the whole two-walker arrangement below rests on that. Putting it on the
    # clock would mean a late pass drew two or three batches at once, which is more drawing,
    # which makes the pass later still. So a game that cannot keep up takes a little longer over
    # its death instead, which is the safe way round. Measured, a fizzling frame spends 132 of
    # its 228 scanlines here, so there is room before that ever comes up.
    FRAMES = 60
    PER_FRAME = ((MODULUS - 1) / FRAMES) + 1

    # HOW THE TURN ENDS. It turns a step at a time toward the killer and stops when it goes PAST
    # him — which is the only test that needs no angle worked out, and no arctangent exists here
    # to work one out with. The cap is a half turn's worth of steps and a couple over, so a
    # killer standing exactly behind you still finishes.
    STEP_ANGLE = FirstPerson::TURN_SPEED
    MOST_TURNS = (FirstPerson::TURN / (2 * STEP_ANGLE)) + 2

    # ...and then the view is drawn a couple more times before the dots start. Both pages have to
    # be holding the SAME settled picture when the drawing stops, or the display spends the whole
    # fizzle alternating between two views a turn-step apart, which reads as a shudder.
    SETTLE = 2

    def initialize(build:, eye:)
      @b = build
      @eye = eye
      declare
    end

    # What the rest of the game asks before it moves or draws.
    def alive = @state == ALIVE
    def showing_the_world = @state <= TURNING

    # ...and what the thing that counts your lives asks: the last dot is down and the view is
    # wholly red, so it is time either to start the floor again or to say the game is over. This
    # stays true until somebody does one of the two.
    def finished = @state == GONE

    # BACK TO THE TOP, for another go at the floor. Everything the death remembered is dropped:
    # which way it was turning and how far it had got, and both walkers back to where they start.
    # They start at 1 rather than 0 because nought is the one number a step like theirs can never
    # leave — see #scatter.
    def start_again
      @state.set ALIVE
      @was.set 0
      @turned.set 0
      @held.set 0
      @lead.set 1
      @lag.set 1
      @lead_done.set 0
      @lag_done.set 0
    end

    # A shot has landed and taken the last of the health. Remember where it came from — the turn
    # is the whole reason a death needs to know.
    def struck_by(guard)
      (@state == ALIVE).then do
        @kill_x.set guard.x
        @kill_y.set guard.y
        @state.set TURNING
        @turned.set 0
        @was.set 0
      end
    end

    # One frame of the turn. Which side of straight-ahead the killer is on decides which way to
    # go, and going PAST him is what says stop.
    #
    # WHICH SIDE HE IS ON, without an angle: point a vector where the eye points, point another
    # at the killer, and ask which way the second is from the first. That is one multiply each
    # way and a subtraction, and its SIGN is the answer — positive one side, negative the other.
    # When the sign is not the one it was last frame, the turn has crossed him and is done.
    def turn
      (@state == TURNING).then do
        @cos.set(@eye[:sin][@eye[:angle] + FirstPerson::QUARTER])
        @sin.set(@eye[:sin][@eye[:angle]])
        @to_x.set(@kill_x - @eye[:x])
        @to_y.set(@kill_y - @eye[:y])
        @side.set((@cos * @to_y) - (@sin * @to_x))

        @now.set(-1)
        (@side > 0.0).then { @now.set 1 }
        # The first frame has nothing to compare against, so it only takes a bearing.
        (@was == 0).then { @was.set @now }
        (@now == @was).then { swing }.else { settle }
        @turned.add 1
        (@turned >= MOST_TURNS).then { settle }
      end
    end

    # ...and one frame of the fizzle, which is the whole of what a frame does once it starts.
    def draw
      # Not on a normal frame: this runs for a second or two at the end of a life and never
      # otherwise. Unsaid, the estimate counts it on every frame — it cannot see through a
      # test the game works out — and then this reads as one of the most expensive things
      # in the game rather than one of the rarest.
      (@state == FIZZLING).then(estimate: { usually: 0 }) { @b.call(:scatter_the_red) }
    end

    private

    def swing
      (@now == 1).then { @eye[:angle].add STEP_ANGLE }.else { @eye[:angle].sub STEP_ANGLE }
    end

    # He is in front of us. Draw the settled view a couple more times so both pages agree, then
    # stop drawing it at all.
    def settle
      @held.add 1
      (@held >= SETTLE).then { @state.set FIZZLING }
    end

    def declare
      b = @b
      @state = b.var :dying, ALIVE
      @kill_x = b.var :_kill_x, 0.0
      @kill_y = b.var :_kill_y, 0.0

      # WORKING ROOM, and every name here carries `dying` for a reason worth knowing: a program's
      # variables are one flat set of names shared by every part that declares any, and the kind
      # of number a name holds is settled by whichever part declares it FIRST. Two of these were
      # called `_side` and `_spot` to begin with, which the view had already declared as whole
      # numbers, and the handles came back holding whole numbers with nothing said.
      @to_x, @to_y, @side, @cos, @sin =
        %i[to_x to_y side cos sin].map { |n| b.var(:"_dying_#{n}", 0.0) }
      @now, @was, @turned, @held, @spot =
        %i[now was turned held spot].map { |n| b.var(:"_dying_#{n}", 0) }

      # The two walkers, one a frame behind the other, and how far each has got. They start at 1
      # because nought is the one number this kind of step can never leave.
      @lead = b.var :_dying_lead, 1
      @lag = b.var :_dying_lag, 1
      @lead_done = b.var :_dying_lead_done, 0
      @lag_done = b.var :_dying_lag_done, 0

      declare_the_scattering
    end

    # A ROUTINE RATHER THAN WRITTEN STRAIGHT IN THE LOOP, for the same reason the status bar is
    # one: the game loop is what the framework keeps in the console's quick memory and it has
    # about a page to spare.
    #
    # AND IT HAS TO STAY IN THAT MEMORY, which is not obvious and was tried the other way.
    #
    # This runs on almost no frames — a second or two at the end of a life — so it looks like
    # an easy thing to turn out of quick memory in favour of something that runs every frame.
    # It is not. A frame that IS fizzling has the whole frame to itself and only just fits in
    # it: run from the cartridge, one frame of the scatter costs more than a frame holds, and
    # the effect stops keeping up — measurably, it stops covering the view at all.
    #
    # So rare is not the same as cheap-to-slow-down. What decides this is the worst frame it
    # ever takes part in, and there it is the only thing running.
    def declare_the_scattering
      @b.func(:scatter_the_red) { scatter_the_next_dots }
    end

    def scatter_the_next_dots
      (@lead_done < MODULUS - 1).then do
        scatter(@lead)
        @lead_done.add PER_FRAME
      end
      # ...and last frame's dots again, onto the page that missed them.
      (@lead_done > PER_FRAME).then do
        scatter(@lag)
        @lag_done.add PER_FRAME
      end
      (@lag_done >= MODULUS - 1).then { @state.set GONE }
    end

    # HOW THE SIX OVERSHOOTS ARE KEPT OUT OF THE STATUS BAR. The prime is a few above the number
    # of pixels, so six of its values name a spot one row below the view — and `inside` clips
    # them for nothing, on both backends: `draw_rect_at` is a run-time position, the one kind
    # `inside` could not clip until the framework learned to hold it to the area (it used to
    # wrap onto the next row on the console instead of stopping, a framework bug that lived here
    # as a worked-around comment for a while).
    def scatter(walker)
      @b.inside(0, 0, ACROSS, DOWN) do
        @b.repeat(PER_FRAME) do
          walker.set((walker * STEP) % MODULUS)
          @spot.set(walker - 1)
          @b.draw_rect_at @spot % ACROSS, @spot / ACROSS, 1, 1, Palette.game[INK]
        end
      end
    end
  end
end
