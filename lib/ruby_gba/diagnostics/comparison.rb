# frozen_string_literal: true

module RubyGBA
  module Diagnostics
    # TWO CARTRIDGES PLAYED SIDE BY SIDE ON THE SAME PRESSES, and where their pictures stop
    # being the same.
    #
    #   result = walk.compare(ours, theirs)
    #   result.drift?         # did they ever differ?
    #   result.drift.frame    # the first frame they did
    #   result.drift.moment   # the named moment before it
    #
    # WHAT IT IS FOR. Somebody rebuilding an existing game wants to know where their cartridge
    # has drifted from the original; a framework change that moves something a frame early
    # wants catching without two people squinting at two screens. Both are the same question:
    # given the same game to play, on which frame do these two first show something different?
    #
    # THE SAME PRESSES ON THE SAME FRAMES. What is compared is a tape: which buttons were down
    # on each frame. A script is played on the first cartridge alone to make one, so where the
    # script watches the game — "walk right until the door" — it is the first cartridge it
    # watched, and the second is handed exactly the walk the first one took. That is the
    # strict comparison: a second cartridge whose door is a frame further off is still walking
    # when the first has stopped, and the two differ from that frame on.
    #
    # EVERY PIXEL OF EVERY FRAME, and it stops at the first frame that differs. One frame out
    # is nearly always every frame after it out too, so the first is the one worth having.
    #
    # +tape+ is the presses, and +first+ and +second+ the two cartridges.
    class Comparison
      # The frame on which the two pictures first differed. +moment+ is the last moment named
      # before that frame was played, for a person to place the frame by: nil when none had
      # been. A moment that names the very frame they differed on is not before it.
      Drift = Data.define(:frame, :moment)

      # What a comparison found. +frames+ is how many frames were played and compared, and
      # +drift+ where the two first differed — nil when they never did.
      Result = Data.define(:frames, :drift) do
        def drift? = !drift.nil?
      end

      def initialize(tape, first, second)
        @tape = tape
        @first = first
        @second = second
      end

      # Play both and compare them, and say what was found.
      def run
        pair = SideBySide.new(Playthrough.power_on(@first), Playthrough.power_on(@second))
        @tape.steps.each do |step|
          step.play(pair)
          break if pair.drift
        end
        Result.new(frames: pair.frames, drift: pair.drift)
      end

      # TWO RUNNING CARTRIDGES PLAYED AS ONE. The lines of a tape play themselves on this as
      # they do on a single playing: a hold goes to both with the same buttons down, a frame
      # at a time, and the two pictures are compared after each. It stops playing at the
      # first frame they differ, part way through a hold if that is where it falls.
      class SideBySide
        attr_reader :frames, :drift

        def initialize(first, second)
          @first = first
          @second = second
          @frames = 0
          @moment = nil
          @drift = nil
        end

        def hold(buttons, frames)
          keys = Playthrough.key_mask(buttons)
          frames.times do
            @first.step(1, keys: keys)
            @second.step(1, keys: keys)
            @frames += 1
            next if @first.same_picture_as?(@second)

            return @drift = Drift.new(frame: @frames, moment: @moment)
          end
        end

        def mark(name) = @moment = name
      end
      private_constant :SideBySide
    end
  end
end
