# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A `wait_vblank` written inside a game loop, which already waits once a pass.
        #
        # Under `frame_sync: :auto` the framework opens every `game_loop` pass with the
        # frame boundary, so a wait written in the body records nothing —
        # Builder#wait_vblank counts it rather than emitting it. Two waits in a pass
        # would run the game at half speed.
        #
        # A warning, not an error: the game plays exactly the same, so nothing is
        # broken. This only says where the wait went.
        #
        # Like OrphanedCondition, it reports from data rather than from the tree: a
        # counted wait leaves no node behind, so there is nothing in the program to
        # find. It ignores the program and runs as an ordinary check in the Validator's
        # list, which keeps every message the developer reads on the one Report#emit
        # path.
        class DroppedFrameSync
          NAME = :dropped_frame_sync

          MESSAGE =
            "This game waits for the screen with `wait_vblank`, but `game_loop` " \
            "already waits once per frame. So this wait does nothing, and the game " \
            "plays the same without it. To place the wait yourself, build with " \
            "`frame_sync: :manual`."

          # @param dropped [Integer] how many waits the game loop already covered
          def initialize(dropped)
            @dropped = dropped
          end

          # One warning however many waits there were — what a developer needs to know
          # is the rule, not each line. So this blames the program rather than any one
          # wait, which is also all it can do: a counted wait leaves no node behind.
          def detect(_program)
            return [] unless @dropped.positive?

            [Finding.new(check: NAME, severity: :warning, message: MESSAGE, node: :program)]
          end
        end
      end
    end
  end
end
