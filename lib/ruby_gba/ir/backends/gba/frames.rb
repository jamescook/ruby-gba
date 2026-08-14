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
        module Frames
          include Constants

          # The names and the cap are the same on every backend, so they live with the IR.
          COUNT = IR::Frames::COUNT
          SEEN = IR::Frames::SEEN
          STEP = IR::Frames::STEP
          MOST = IR::Frames::MOST

          # Added to the count inside the screen's interrupt. It runs sixty times a second
          # whatever the game is doing, so it is kept to what it must be: read, add, write.
          # r0 and r12 are both saved by the BIOS before it enters here.
          def emit_frame_count
            load_var(ACC, COUNT)
            emit(ASM.add_imm(ACC, ACC, 1))
            store_var(ACC, COUNT)
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
          # Holding it here rather than setting the marks at boot is deliberate. Anything touched
          # at boot is given its place in memory BEFORE the program's own variables, which pushes
          # every one of them along — and the first variable is the only one whose address the
          # console can name in a single instruction, so moving it makes every read of it dearer.
          # Two instructions here cost less than that, until the day an address is cheap
          # whichever variable it belongs to.
          def emit_frame_step
            load_var(ACC, COUNT)
            load_var(TMP, SEEN)
            store_var(ACC, SEEN)          # this pass's mark, for the next one to measure from
            emit(ASM.sub_reg(ACC, ACC, TMP))

            under = gensym
            emit(ASM.cmp_imm(ACC, MOST))
            emit_branch(:bcond, under, cond: :le)
            emit(ASM.load_immediate(ACC, MOST))
            place_label(under)

            over = gensym
            emit(ASM.cmp_imm(ACC, 1))
            emit_branch(:bcond, over, cond: :ge)
            emit(ASM.load_immediate(ACC, 1))
            place_label(over)
            store_var(ACC, STEP)
          end
        end
      end
    end
  end
end
