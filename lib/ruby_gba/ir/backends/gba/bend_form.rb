# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # WHICH OF THE TWO WAYS A ROW-BY-ROW BEND IS LOWERED, decided from the program alone.
        #
        # Both ways answer the same question — where does this row sit? — and the display asks
        # it once per line as it builds the picture. What differs is who answers.
        #
        # THE INTERRUPT is the general one. The display announces the end of every line it
        # draws, the console stops the game, and the block runs right there with the whole
        # program in reach: it can call a routine, set a variable, read anything. That is what
        # makes it the primitive. It is also why it is dear — being stopped and restarted 228
        # times a frame costs more than the block usually does, and most of THAT is the
        # console's own work on the way in and out, which nothing we write reaches.
        #
        # THE COPIER is the cheap one. One of the console's copying engines can be told "move
        # one number into this register at the end of every line", and from then on it feeds
        # the scroll register itself with the CPU untouched. The per-line cost goes to nothing.
        # The price is that a copier moves numbers and cannot run a program, so all 160 of them
        # have to be worked out in advance, once a frame, into a table it reads.
        #
        # So the copier can only take a bend whose block IS one number — no statements beside
        # it. Ask for anything more and the interrupt is what can answer.
        #
        # AND ONE ENGINE PER BENDING LAYER, since an engine feeds one register. Three of the
        # four can be lent out, which is where the ceiling comes from — and it lands in a
        # comfortable place: with the frame's own body kept in the console's quick memory,
        # where a real build puts a body this busy, three tables still cost a good deal less
        # than being interrupted 228 times. (Left in the cartridge the two come out close at
        # three, which is a reason to leave the ceiling where the hardware puts it rather than
        # to start choosing by price.)
        #
        # THIS ANSWER IS ASKED FOR IN TWO PLACES, here where the bend is emitted and in the
        # cost estimate, which has to charge for the lowering that will really run. It lives in
        # one place so the two cannot drift apart — the same reason {LoopForm} does.
        module BendForm
          module_function

          # THE ENGINES A BEND CAN RIDE, in the order they are handed out. There are four in
          # the console. The last is the general copier every fill and upload uses, so it can
          # never be given away; the other three can, but only while nothing else wants them.
          #
          # The three go in this order because the console serves the lower-numbered one first
          # when two want to move at the same moment, and a line-end move is the one thing
          # here that cannot wait.
          FREE_ENGINES = [0, 1, 2].freeze

          # ...and the pair sampled sound is entitled to. It feeds a stream of PCM to the
          # sound hardware continuously, which is exactly the standing claim on an engine a
          # bend makes, so the two cannot share. Measured on the emulator, they do not fail
          # halfway: hand a bend the engine the sound was using and the game goes SILENT,
          # with the picture none the wiser.
          #
          # Today the mixer sums everything into one voice and takes only the first of these.
          # The second is held back on purpose rather than lent out — a game that grew a
          # second voice would otherwise lose its sound to a bend, and nothing about adding a
          # bending layer suggests that is what happened.
          SOUND_ENGINES = [1, 2].freeze

          # How many bends this program can feed from an engine: all three when nothing else
          # is using them, one when it plays sampled sound.
          def channels(program)
            engines(program).length
          end

          def engines(program)
            return FREE_ENGINES if program.walk.none? { |node| node.kind == :play_sample }

            FREE_ENGINES - SOUND_ENGINES
          end

          def bends(program)
            program.walk.select { |node| node.kind == :scroll_rows }
          end

          # Whether this program's bends are fed by the copier rather than by a per-line
          # interrupt. All of them or none: the interrupt costs what it costs the moment one
          # bend needs it, and a second lowering beside it would add a table to fill for no
          # saving at all.
          def copier?(program)
            bends = bends(program)
            !bends.empty? && refusal(program, bends).nil?
          end

          # WHY THE INTERRUPT WAS KEPT, in the words an author would use, or nil when the
          # copier took it. Read off the same test the answer comes from, so "it did not" and
          # "here is why" can never disagree.
          def kept_interrupt_reason(program)
            bends = bends(program)
            bends.empty? ? nil : refusal(program, bends)
          end

          def refusal(program, bends)
            if bends.length > channels(program)
              too_many(program, bends)
            elsif (busy = bends.find { |node| !node.children.empty? })
              "the block of :#{busy.name} does more than work one number out"
            elsif program.walk.none? { |node| node.kind == :wait_vblank }
              "the program never waits for a frame, so there is no moment to fill the table in"
            end
          end

          # More bending layers than there are engines to feed them. Naming what took the
          # others is the whole use of this line: with sampled sound in the game there is one
          # engine, and moving a bend is not what an author would think to try.
          def too_many(program, bends)
            free = channels(program)
            taken = free < FREE_ENGINES.length ? ", and this game's sampled sound holds the rest" : ""
            "there are #{bends.length} bending layers and #{free} copying #{free == 1 ? 'engine' : 'engines'} " \
              "free#{taken}"
          end
        end
      end
    end
  end
end
