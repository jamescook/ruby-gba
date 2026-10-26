# frozen_string_literal: true

module VBlank
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
          include Console::Hardware

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

          # THE COUNT STARTS AT NOUGHT, for a game that reads it as frames since power-on — put
          # before the screen's interrupt is armed, so that every frame from then on is in it.
          # This console's memory is not cleared at power-on, so without this the count starts
          # wherever the memory happened to be. A game that never reads it needs nothing: the
          # marks below only ever look at differences.
          def emit_clear_frame_count
            @emitter.emit_number(ACC, 0)
            @primitives.store_var(ACC, COUNT)
          end

          # START COUNTING FROM HERE, which is where the game loop begins. The frames that went by
          # before it were spent setting up — writing video memory, painting the first picture
          # — and they are not frames the game missed. Counted as missed, the first pass ran
          # every routine that keeps real time that many times over before anything was shown,
          # so a game that opens on a flash lost the flash's brightest frame to the setting up.
          # Marked here, the first wait wakes at the next frame and the first pass is one frame,
          # the same as on every backend that has no setting up to count.
          def emit_reset_frame_mark
            @primitives.load_var(ACC, COUNT)
            @primitives.store_var(ACC, SEEN)
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
            @emitter.emit_number(ACC, MOST)
            @emitter.place_label(under)

            over = @emitter.gensym
            @emitter.emit(ASM.cmp_imm(ACC, 1))
            @emitter.emit_branch(:bcond, over, cond: :ge)
            @emitter.emit_number(ACC, 1)
            @emitter.place_label(over)
            @primitives.store_var(ACC, STEP)
          end

          # IS THE PASS THAT JUST ENDED LATE? — asked by a screen that may show a late page at
          # once (see IR::LatePages). Late is not "a break went by": a game aiming at thirty sees
          # one go by on every pass, and on time. It is "more breaks went by than the game aims to
          # take", which the screen says as its pace — so a game aiming at thirty is late when a
          # pass runs into a third frame, and one aiming at sixty when a pass runs into a second.
          #
          # ...plus one, for a page that would tear, after a page shown part way down the picture.
          # The pass after it started part way down too, so the break coming was never one it
          # could make; reaching the break after that is on time for it, and showing it part way
          # down sooner would tear for nothing. A page that finishes IN that break is shown, since
          # nothing tears there and waiting would cost a whole picture.
          PACE = :__frames_late_pace
          SPENT = :__frames_break_spent

          # Jump to +on_time+ when fewer breaks went by during the pass than the pace allows — and,
          # with +spent+, one fewer than that after a page shown part way down.
          def emit_branch_if_on_pace(on_time, spent: false)
            @primitives.load_var(ACC, COUNT)
            @primitives.load_var(TMP, SEEN)
            @emitter.emit(ASM.sub_reg(ACC, ACC, TMP)) # the breaks that went by...
            if spent
              # ...held to MOST, as a step is, so the count spent at power-on is past it whatever
              # the marks held then and however long the first pass took.
              within = @emitter.gensym
              @emitter.emit(ASM.cmp_imm(ACC, MOST))
              @emitter.emit_branch(:bcond, within, cond: :le)
              @emitter.emit_number(ACC, MOST)
              @emitter.place_label(within)
              @primitives.load_var(TMP, SPENT)
              @emitter.emit(ASM.sub_reg(ACC, ACC, TMP)) # ...less one already spent
            end
            @primitives.load_var(TMP, PACE)
            @emitter.emit(ASM.cmp_reg(ACC, TMP))
            @emitter.emit_branch(:bcond, on_time, cond: :lt)
          end

          # Whether the page just shown was shown part way down the picture, for the next pass.
          def emit_note_break_spent(spent)
            @emitter.emit_number(ACC, spent ? 1 : 0)
            @primitives.store_var(ACC, SPENT)
          end

          # The breaks a pass may take and be on time, from the screen that is up.
          def emit_set_pace(frames)
            @emitter.emit_number(ACC, frames)
            @primitives.store_var(ACC, PACE)
          end

          # NO PAGE IS SHOWN PART WAY DOWN BEFORE THE FIRST PASS HAS BEEN COUNTED: the marks are
          # rubbish at power-on (see #emit_frame_step), and counting more breaks as spent than a
          # pass can take keeps the first page from being shown part way down — which is also
          # what keeps the picture from being switched on part way down the screen. A first page
          # finished in the break may still be shown there, where nothing tears. Every wait after
          # it says what it spent.
          def emit_pace_at_power_on
            @emitter.emit_number(ACC, MOST + 1)
            @primitives.store_var(ACC, SPENT)
          end
        end
      end
    end
  end
end
