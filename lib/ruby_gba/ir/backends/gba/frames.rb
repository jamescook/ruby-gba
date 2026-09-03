# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # HOW MANY FRAMES A PASS OF THE GAME LOOP REALLY TOOK.
        #
        # A game loop waits for the screen, does its work, and comes round again. While the work
        # fits in the time between two frames, one pass IS one frame and nothing has to count.
        # When the work does not fit, a pass spans two frames, or three — and anything that was
        # counting passes and calling them frames is now counting the wrong thing.
        #
        # The screen keeps its own time whatever the game is doing: it raises an interrupt sixty
        # times a second, and that interrupt is already being handled here (it is what wakes the
        # wait). So the count is free to come by — add one in the handler — and the difference
        # between one pass and the next is how many frames the last pass spanned.
        #
        # WHY THE COUNTING IS EXACT. The wait does not return "at some point after a frame": it
        # sleeps until the NEXT frame interrupt after it is asked. So a pass that overran by a
        # frame wakes two interrupts later than it started, and the difference is two. There is
        # no drift to accumulate and no fraction to carry, because a console is late by whole
        # frames or not at all.
        #
        # Holds no state of its own — the count and its marks live in named variables (below),
        # not ivars, so this is two emission recipes rather than a real collaborator with
        # anything to encapsulate. Takes emitter: and primitives: purely to reach load_var/
        # store_var/emit/etc without going through GBA's shared self.
        class Frames
          include Constants

          # The names and the cap are the same on every backend, so they live with the IR.
          COUNT = IR::Frames::COUNT
          SEEN = IR::Frames::SEEN
          STEP = IR::Frames::STEP
          MOST = IR::Frames::MOST

          def initialize(emitter:, primitives:)
            @emitter = emitter
            @primitives = primitives
          end

          # Added to the count inside the screen's interrupt. It runs sixty times a second
          # whatever the game is doing, so it is kept to what it must be: read, add, write.
          # r0 and r12 are both saved by the BIOS before it enters here.
          def emit_frame_count
            @primitives.load_var(ACC, COUNT)
            @emitter.emit(ASM.add_imm(ACC, ACC, 1))
            @primitives.store_var(ACC, COUNT)
          end

          # ...and read at the top of each pass: the difference since last time, held between one
          # and MOST, left where anything that needs it can read it.
          #
          # HELD AT BOTH ENDS, and the low end is not tidiness. This console's memory is not zero
          # at power-on, so on the very first pass both marks are rubbish and their difference
          # can be anything at all — including a negative, which would tell a loop to run no
          # times and a beat to count backwards. One is the floor because a pass is always worth
          # at least the frame it ran in.
          #
          # Held HERE rather than by clearing the two marks at boot, because a guard that lives
          # with the number it guards cannot be undone from a distance: nothing added to the
          # boot sequence later, in any order, can put a wild difference back.
          def emit_frame_step
            @primitives.load_var(ACC, COUNT)
            @primitives.load_var(TMP, SEEN)
            @primitives.store_var(ACC, SEEN)  # this pass's mark, for the next one to measure from
            @emitter.emit(ASM.sub_reg(ACC, ACC, TMP))

            under = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(ACC, MOST))
            @emitter.emit_branch(:bcond, under, cond: :le)
            @emitter.emit(ASM.load_immediate(ACC, MOST))
            @emitter.place_label(under)

            over = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(ACC, 1))
            @emitter.emit_branch(:bcond, over, cond: :ge)
            @emitter.emit(ASM.load_immediate(ACC, 1))
            @emitter.place_label(over)
            @primitives.store_var(ACC, STEP)
          end
        end
      end
    end
  end
end
