# frozen_string_literal: true

module RubyGBA
  module IR
    class CostModel
      # WHAT THE MODEL CONCLUDES ABOUT ONE THING, as a value rather than a bare hash.
      #
      # Each of these is a small finished answer — what a scene costs, what the mixer
      # costs, how long a list can get — handed to the report to print, to a guardrail to
      # warn about, and to the JSON. Their fields are ours, fixed where each is written, so
      # a reader asking for a field that is not there says so instead of quietly getting
      # nothing and printing a blank number.
      #
      # WHETHER SOMETHING IS OVER ITS BUDGET IS NOT STORED. It is the cost against the
      # budget, and a record carrying all three can hold a combination that cannot happen —
      # a cost under its budget and an over of true. So the two numbers are the record and
      # the verdict is asked for.
      module Verdict
        # A standing per-frame cost judged against a budget: the shared shape under the
        # mixer, a row-by-row bend, and a frame's timer ticks.
        module Budgeted
          def over? = cost > budget
        end

        # One scene, judged against the budget for the display mode that scene runs in — so
        # a heavy direct-color scene is caught even when another scene is double-buffered.
        Scene = Data.define(:name, :node, :mode, :steady_cost, :budget) do
          def over? = steady_cost > budget
        end

        # One song the program plays. A score is unrolled into a comparison per note, so a
        # long tune is real recurring work on its own.
        Song = Data.define(:name, :notes, :steady_cost, :budget, :source) do
          def over? = steady_cost > budget
        end

        # The software mixer, summing every sounding voice into the output buffer once a
        # frame. Priced at its worst case, which is every voice.
        Mixer = Data.define(:voices, :samples_per_frame, :rate, :cost, :budget) do
          include Budgeted
        end

        # Bending backgrounds row by row: the display interrupts the game on every line it
        # counts, and each bend's offset is worked out again on every visible line. The two
        # are kept apart because most of the cost is the interrupting, not the block — a
        # reader hunting their frame would otherwise rewrite the block and find it no faster.
        Bend = Data.define(:layers, :lines, :interrupts, :offsets, :cost, :budget) do
          include Budgeted
        end

        # Sprites kept out of a fade placed in the stack. The console names every sprite
        # with one bit, so the only way to hold an effect off SOME of them is to write a
        # second, invisible sprite over each — which is a table write a frame each, and
        # the first thing in the fade family that is not free.
        KeptSprites = Data.define(:layers, :sprites, :cost, :budget) do
          include Budgeted
        end

        # Every timer handler a frame runs, together — they all ride the same interrupt.
        Ticks = Data.define(:timers, :cost, :budget) do
          include Budgeted
        end

        # One timer inside that: the rate it asked for, the rate the console can really
        # deliver, and how many ticks a frame that comes to. The interrupt and the body are
        # priced apart, because a rate too fast for its handler is answered by the rate
        # rather than by the body.
        Timer = Data.define(:name, :hz, :delivered, :ticks, :each, :interrupts, :body, :cost)

        # How long a list can get before the frame stops fitting. Reported only for a walk
        # whose break-even is reachable — a loop that fits even with the list full is not
        # interesting.
        ListWalk = Data.define(:list, :break_even, :cap, :budget, :steady, :node)

        # One place the program leans on a weight, for the question of whether it is leaning
        # far outside where that weight was measured: what it is, how many times a frame,
        # and what that comes to.
        Use = Data.define(:what, :count, :cost)

        # What a list walk was counted at, and whether the author said so or the model
        # guessed — the one assumption in the frame figure a reader can correct.
        ListLength = Data.define(:name, :counted, :capacity, :said)

        # The same for a walk over a fixed set of slots that acts on the ones in use (a
        # pool): every slot is asked, so the walk itself is counted whole, and this is how
        # many of them the body was counted for.
        LiveSlots = Data.define(:name, :counted, :slots, :said)

        # Work the model cannot price to a single number because it depends on something
        # only known as the game runs — how far a value ranges, and what that costs at each
        # end. Loud, because a frame figure that quietly left it out would read as fine.
        Unpriced = Data.define(:weight, :varies, :from, :to, :count, :cost, :what)
      end
    end
  end
end
