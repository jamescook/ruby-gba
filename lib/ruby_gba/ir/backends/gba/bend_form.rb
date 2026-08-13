# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # WHICH OF THE TWO WAYS A ROW-BY-ROW BEND IS LOWERED, decided from the program alone.
        #
        # WHERE THE OFFSETS COME FROM IS THE SAME EITHER WAY. The block is run for all 160 rows
        # in the gap between frames, into a table. That is where everything else about a frame
        # is settled too — the sprites' positions, a background's scroll — so a bend shows the
        # frame that moved it at the same moment they do. Working the rows out while the
        # picture is being drawn instead would show a bend a frame ahead of the sprite standing
        # on it, and would race the display down the screen besides.
        #
        # What the two ways differ in is WHO MOVES a row's number out of that table and into
        # the scroll register, once per line, as the display asks for it.
        #
        # THE COPIER is the cheap one, and the usual one. One of the console's copying engines
        # can be told "move one number into this register at the end of every line", and from
        # then on it feeds the register itself with the CPU untouched. The per-line cost goes
        # to nothing at all, so a bend costs only the table.
        #
        # ONE ENGINE PER BENDING LAYER, since an engine feeds one register. Three of the four
        # can be lent out, which is where the ceiling comes from.
        #
        # THE INTERRUPT is the fallback, for when there is no engine left. The display
        # announces the end of every line it draws, the console stops the game, and the
        # handler reads that line's number out of the table and writes it. It does the same
        # work the engine would, so the picture is the same — it just costs being stopped and
        # restarted 228 times a frame, most of which is the console's own doing on the way in
        # and out and nothing we write reaches.
        #
        # A PROGRAM WITH NO FRAME has nowhere to fill a table, and then the interrupt runs the
        # block itself, line by line. Nothing is paced in such a program, so there is nothing
        # for the bend to be in step with.
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

          # Whether this program's bends are worked out into a table ahead of the frame. They
          # are, whenever there is a frame to work them out in — which is what a wait for one
          # is. A program with no frame has no such moment and runs its block per line instead.
          def latched?(program)
            !bends(program).empty? && program.walk.any? { |node| node.kind == :wait_vblank }
          end

          # ...and the other side of the same answer: a bend that runs its block per line,
          # because the program it is in never waits for a frame.
          def live?(program)
            !bends(program).empty? && !latched?(program)
          end

          # Whether this program's tables are fed to the display by a copying engine rather
          # than by a per-line interrupt. All of them or none: the interrupt costs what it
          # costs the moment one bend needs it, and feeding one layer by engine beside it
          # would save nothing.
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
            if !latched?(program)
              "the program never waits for a frame, so there is no moment to work the rows out in"
            elsif bends.length > channels(program)
              too_many(program, bends)
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
