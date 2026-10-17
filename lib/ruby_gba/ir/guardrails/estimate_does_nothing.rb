# frozen_string_literal: true

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # An `estimate:` written on a list, a pool, a `repeat`, a `.then` or a stretched shape.
        #
        # Nothing reads one (why is at Builder#record_estimate_line), which is why this is a
        # warning and not an error: the game plays exactly the same, and the author can delete
        # the hints when it suits them.
        #
        # Like DroppedFrameSync it reports from data rather than from the tree, since a hint
        # leaves no node behind. One warning names every line, rather than one a line:
        # the rule is the news, and a game written with hints has many of them.
        class EstimateDoesNothing
          NAME = :estimate_does_nothing
          PLAIN_NAME = "a hint about cost that nothing reads"

          # @param lines [Array<String, nil>] where each `estimate:` was given ("hero.rb:12"),
          #   nil for a line the builder could not place
          def initialize(lines)
            @lines = lines.compact.uniq
          end

          def detect(_program)
            return [] if @lines.empty?

            [Finding.new(check: NAME, severity: :warning, message: message, node: :program)]
          end

          private

          def message
            where = @lines.size == 1 ? @lines.first : "#{@lines[0...-1].join(', ')} and #{@lines.last}"
            "This game gives `estimate:` at #{where}. `estimate:` has no effect. The build measures " \
              "the game while the game runs, and does not read `estimate:`. The game plays the same with " \
              "or without it. Remove `estimate:` from #{@lines.size == 1 ? 'this line' : 'these lines'}."
          end
        end
      end
    end
  end
end
