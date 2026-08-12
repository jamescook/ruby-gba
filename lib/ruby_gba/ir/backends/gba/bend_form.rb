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
        # THIS ANSWER IS ASKED FOR IN TWO PLACES, here where the bend is emitted and in the
        # cost estimate, which has to charge for the lowering that will really run. It lives in
        # one place so the two cannot drift apart — the same reason {LoopForm} does.
        module BendForm
          module_function

          # How many bends the copier can take: one for each engine free to sit on a scroll
          # register for the whole frame. Only the first engine is, so far — the other three
          # are the general copier every fill and upload uses, and the pair the sampled sound
          # feeds itself with.
          CHANNELS = 1

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
            if bends.length > CHANNELS
              "there is more than one bending layer"
            elsif (busy = bends.find { |node| !node.children.empty? })
              "the block of :#{busy.name} does more than work one number out"
            elsif program.walk.none? { |node| node.kind == :wait_vblank }
              "the program never waits for a frame, so there is no moment to fill the table in"
            end
          end
        end
      end
    end
  end
end
