# frozen_string_literal: true

module VBlank
  module Live
    # HOW FAST A PLAY WENT, handed back when it ends. A pass is one time round the game's loop,
    # and a frame is one of the console's sixtieths of a second that went by. A machine that keeps
    # up plays one pass a frame; a slower one plays fewer passes than frames, and the game, which
    # counts one frame a pass, runs that much slower. Fast forward plays more passes than frames,
    # and the game runs that much faster. The seconds run to the end of the last frame
    # the play reached. +stopped_itself+ is a game that halted or came to its end, rather than one
    # the player stopped.
    Rate = Data.define(:passes, :frames, :seconds, :stopped_itself) do
      def initialize(passes:, frames:, seconds:, stopped_itself: false) = super

      def stopped_itself? = stopped_itself

      def passes_per_second = per_second(passes)
      def frames_per_second = per_second(frames)

      private

      def per_second(count) = seconds.positive? ? count / seconds.to_f : 0.0
    end
  end
end
