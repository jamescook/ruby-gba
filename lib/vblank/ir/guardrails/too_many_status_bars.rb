# frozen_string_literal: true

require VBlank.root.join("lib/vblank/ir/modes").to_s
require VBlank.root.join("lib/vblank/ir/stacking").to_s

module VBlank
  module IR
    module Guardrails
      module Checks
        # MORE THAN ONE STATUS BAR ON ONE SCREEN.
        #
        # A status bar covers the screen from its top row down to the bottom, so two at once
        # would each be hiding the other's rows — and on the Color it is the console's one
        # window, which there is one of. Counted a screenful at a time (IR::Stacking#screenfuls),
        # so each scene can show a bar of its own. What a bar cannot share the display with is
        # Checks::StatusBarCannotShare's.
        class TooManyStatusBars
          NAME = :too_many_status_bars
          PLAIN_NAME = "more than one status bar on one screen"

          def detect(program)
            Stacking.screenfuls(program).each do |screenful|
              bars = screenful.scenery.select(&:bar?)
              next if bars.size <= 1

              return [Finding.new(check: NAME, severity: :error, node: bars[1], message: message(bars, screenful.scene))]
            end
            []
          end

          # Why the bars are refused, or nil when they fit — the words the interpreter and each
          # lowering stop with too.
          def refusal_message(program)
            detect(program).first&.message
          end

          private

          def message(bars, scene)
            subject = scene ? "The scene :#{Modes.strip_scene_prefix(scene)}" : "This game"
            hint = scene ? "" : " Each scene can show its own status bar."
            "#{subject} shows #{bars.size} status bars at one time (#{bars.map { |bar| ":#{bar.name}" }.join(', ')}). " \
              "A status bar covers the screen from its top to the bottom. So only one status bar can show at " \
              "one time. To fix this, show one status bar.#{hint}"
          end
        end
      end
    end
  end
end
