# frozen_string_literal: true

module VBlank
  module Effects
    module Packs
      # Pixelating the screen over time — the scene change where the picture breaks up
      # into bigger and bigger blocks, is swapped for the next one while nobody can read
      # it, and comes back together.
      #
      # `pixelate` shows the picture in blocks of one size and is kernel, because the
      # display does it in a register. Walking that size over frames is not — it is a few
      # variables and a routine that runs each frame, so it lives here, written in the
      # same verbs a game is written in. It is the screen fade's sibling and is built the
      # same way (see ScreenFade), which is why the two read alike at the call site.
      #
      # WHAT IS WALKED IS HOW FAR THE PICTURE HAS BROKEN UP, from 0 (as drawn) to the
      # biggest block there is, and the size of a block is one more than that. Counting
      # from nothing is what lets the guardrail below read a `pixelate_in` off the tree
      # the way the fade's reads a `fade_in`: it is the only thing that sets the target
      # to nought.
      #
      # WHY IT HOLDS A FRACTION. There are sixteen sizes and a walk lasts tens of frames,
      # so a whole-number step would either jump or stand still. A variable that holds a
      # fraction steps by exactly the distance over the frames asked for and lands on the
      # last one, so the number an author writes is the number they get. The display is
      # handed the whole part, so the picture moves on to the next size when the walk has
      # got that far.
      module ScreenPixelate
        # The hidden state, named with the framework's underscore prefix so a game's own
        # variables can never collide with it.
        BROKEN = :__pixelate_broken   # how far the picture has broken up, 0.0 to FULL
        TARGET = :__pixelate_target   # where the walk is heading
        STEP = :__pixelate_step       # how far it moves each frame
        ACTIVE = :__pixelate_active   # 1 while the walk is running
        SHOWN = :__pixelate_shown     # the size of block on screen now, 1 to the biggest
        ROUTINE = :__pixelate_tick

        # As far as a picture breaks up: every size of block past the first.
        FULL = (IR::Backends::Blocks::LARGEST - 1).to_f

        # TARGET starts here, which is what lets the guardrail below tell a real
        # `pixelate_in` from the declaration: nothing else writes this variable.
        NEVER_WALKED = -1.0

        DEFAULT_FRAMES = 30 # half a second — a scene change, not a blink

        # Break the picture up into bigger and bigger blocks, until they are the biggest
        # the console draws. Call it once, at the moment the change begins; the framework
        # walks the size for you on every frame from there.
        #
        #   pixelate_out                    # over half a second
        #   pixelate_out frames: 12         # faster
        #   pixelate_out duration: 1.5      # the same, said in seconds
        #
        # The picture is not redrawn and nothing is lost: `pixelate_in` brings it back
        # untouched. Calling this again while a walk runs turns it round from where it is.
        #
        # `under:` leaves a layer and everything in front of it as drawn, as it does for
        # `pixelate`, and it holds for the whole game: `pixelate_in` comes back the same
        # way with nothing to repeat.
        #
        #   pixelate_out under: :ui
        #
        # @param frames [Integer, nil] how long the walk takes, in frames
        # @param duration [Numeric, nil] how long it takes, in seconds (instead of frames)
        # @param under [Symbol, nil] a layer left as drawn with everything in front of it
        def pixelate_out(frames: nil, duration: nil, under: nil)
          start_pixelate_walk(FULL, frames, duration, under: under)
        end

        # Bring the picture back together — the other half of `pixelate_out`.
        #
        #   pixelate_in                # back at the speed it went out
        #   pixelate_in frames: 10     # back faster than it left
        #
        # @param frames [Integer, nil] how long it takes, in frames
        # @param duration [Numeric, nil] how long it takes, in seconds
        def pixelate_in(frames: nil, duration: nil)
          start_pixelate_walk(0.0, frames, duration, default: nil)
        end

        # How big a block is on screen right now, as a value the game can read: 1 is the
        # picture as drawn and 16 is the biggest block there is. It is the size this walk
        # has put on screen; a size a game sets itself with `pixelate` is not read back here.
        #
        # THIS IS WHAT MAKES A SCENE CHANGE WRITABLE. The picture is hardest to read at the
        # biggest block, so that is the moment to swap what is drawn, and the swap has to
        # wait for the walk to arrive:
        #
        #   leaving = var :leaving, 0
        #   (lives <= 0).then { pixelate_out; leaving.set! 1 }
        #   ((leaving == 1) & (pixelate_size == 16)).then do
        #     state.set! GAME_OVER
        #     pixelate_in
        #     leaving.set! 0
        #   end
        #
        # THE FLAG IS NOT DECORATION. The size reads 16 on the old scene's last frame and
        # again on the new scene's first, which is what puts both of them in the biggest
        # blocks — so a test on the size alone is true twice, and the second time would
        # swap again.
        #
        # A value rather than a yes-or-no on purpose: half way is a place to act too.
        def pixelate_size
          screen_pixelate_state[:shown]
        end

        def self.checks = CHECKS

        # A walk with no frames to happen on. The size is moved a little every frame, at
        # the frame boundary a `game_loop` gives it; with no game loop the call sets its
        # target and nothing ever reads it.
        class NeedsGameLoop
          NAME = :pixelate_needs_game_loop
          PLAIN_NAME = "a pixelate with no frames to run on"

          MESSAGE =
            "This game pixelates the screen with `pixelate_out` or `pixelate_in`, but it has " \
            "no `game_loop`. The size of a block changes a little on every frame, so it needs " \
            "frames to run on. With no game loop there are none, and the screen never changes. " \
            "To fix this, put the game in a `game_loop`. To set one size with no loop, use " \
            "`pixelate`."

          def detect(program)
            # The whole tree each time: an `if` keeps its else branch beside it, not under it.
            return [] unless program.walk.any? { |node| node.kind == :func && node.name == ROUTINE }
            return [] if program.walk.any? { |node| node.kind == :call && node.target == ROUTINE }

            [IR::Guardrails::Finding.new(check: NAME, severity: :warning, message: MESSAGE,
                                         node: ScreenPixelate.walk_starts(program).last || :program)]
          end
        end

        # A screen pixelated out and never brought back. The picture is all still there,
        # which is what makes this hard to spot: the game runs and draws everything it
        # meant to, in blocks too big to read. The usual way in is to pixelate out for a
        # scene change and forget the other half.
        class PixelatedOutNeverIn
          NAME = :pixelated_out_never_in
          PLAIN_NAME = "a pixelate out with no pixelate in"

          MESSAGE =
            "This game calls `pixelate_out` and never calls `pixelate_in`. The picture stays " \
            "in the biggest blocks, which are too big to read. The game is still running " \
            "behind them. To fix this, call `pixelate_in` when the picture must come back."

          def detect(program)
            starts = ScreenPixelate.walk_starts(program)
            return [] if starts.empty? || starts.any? { |node| node.value.value.zero? }

            [IR::Guardrails::Finding.new(check: NAME, severity: :warning, message: MESSAGE, node: starts.last)]
          end
        end

        # Where the author started a walk: every write of the target but the declaration's,
        # which is the one below nothing.
        def self.walk_starts(program)
          program.walk.select do |node|
            node.kind == :set && node.var == TARGET && node.value.kind == :int && !node.value.value.negative?
          end
        end

        private

        # Point the walk at a new target and set it running: the one path both verbs take.
        # A `default:` of nil keeps the speed of the walk before, which is what lets
        # `pixelate_in` be written on its own.
        def start_pixelate_walk(target, frames, duration, default: DEFAULT_FRAMES, under: nil)
          place_screen_pixelate!(under) if under
          state = screen_pixelate_state
          state[:target].set! target
          if frames || duration || default
            state[:step].set! FULL / pixelate_step_count(frames, duration, default)
          end
          state[:active].set! 1
          nil
        end

        # The walk's variables and the routine that moves them, declared once however many
        # places in the game pixelate.
        #
        # THE SIZE IS SHOWN AND THEN MOVED, the order the screen fade keeps, and the size
        # shown is kept beside the walk because the two are a step apart: `pixelate_size`
        # reads what is on screen, not where the walk has got to.
        #
        # That pair is what makes a scene change clean on both sides. The walk out arrives,
        # and the frame a game reads the biggest size on is a frame showing it — the old
        # scene's last. The game swaps and turns the walk round there, and the next frame
        # shows the size the walk is still standing at before it moves off: the new scene's
        # first frame is at the biggest block too. Read where the walk had got to instead,
        # or moved before it was shown, and one of the two scenes is seen a size smaller.
        #
        # Once the walk reaches its target the routine stops writing and the display holds
        # the last size it was given.
        def screen_pixelate_state
          @screen_pixelate_state ||= begin
            broken = var BROKEN, 0.0
            target = var TARGET, NEVER_WALKED
            step = var STEP, FULL / (DEFAULT_FRAMES - 1)
            active = var ACTIVE, 0
            shown = var SHOWN, 1

            # The body is built once the game is written, so the place every verb agreed
            # on is known by then.
            once_a_frame(ROUTINE) do
              (active == 1).then do
                shown.set! broken.to_i + 1
                pixelate shown, under: @screen_pixelate_place
                (broken == target).then { active.set! 0 }
                                  .else { broken.approach! target, step }
              end
            end

            { broken: broken, target: target, step: step, active: active, shown: shown }
          end
        end

        # WHERE THIS GAME'S PIXELATE SITS, and there is one of it — which things are drawn
        # in blocks is settled before the game runs (see `pixelate`). Said on either verb
        # it holds for both.
        def place_screen_pixelate!(under)
          if @screen_pixelate_place && @screen_pixelate_place != under
            raise ArgumentError,
                  "This game already pixelates with `under: :#{@screen_pixelate_place}`, and now with " \
                  "`under: :#{under}`. A game pixelates from one place in the stack, because which " \
                  "things are drawn in blocks is settled once, before it runs. To fix this, give " \
                  "every `pixelate_out` the same `under:`."
          end
          @screen_pixelate_place = under
        end

        # How many steps get from one end to the other over that many frames (see WalkLength).
        def pixelate_step_count(frames, duration, default)
          WalkLength.steps(frames, duration, default, "a pixelate").to_f
        end

        # Down here because the check classes it names are declared above it.
        CHECKS = Ractor.make_shareable([NeedsGameLoop.new, PixelatedOutNeverIn.new])
      end
    end
  end
end
