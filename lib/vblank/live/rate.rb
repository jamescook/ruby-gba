# frozen_string_literal: true

module VBlank
  module Live
    # HOW FAST A PLAY WENT, handed back when it ends. A pass is one time round the game's loop,
    # and a frame is one of the console's sixtieths of a second. A machine that keeps up plays
    # one pass a frame; a slower one shows fewer pictures than that, while the game, told how
    # many frames each pass took, still moves on by every frame. The seconds run to the end of
    # the last frame the play reached.
    Rate = Data.define(:passes, :frames, :seconds) do
      def passes_per_second = per_second(passes)
      def frames_per_second = per_second(frames)

      private

      def per_second(count) = seconds.positive? ? count / seconds.to_f : 0.0
    end
  end
end
