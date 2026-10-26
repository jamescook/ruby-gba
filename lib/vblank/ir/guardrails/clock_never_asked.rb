# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # A GAME THAT SHOWS THE TIME AND NEVER ASKS WHETHER THERE IS A CLOCK. The console has no
        # clock of its own; some cartridges carry one, and most emulators give a cartridge none
        # unless they are told to. A clock whose watch battery ran out was never set. Either way
        # every reading is 0 (see IR::Clock), so a game written on a desktop, where the clock
        # always works, shows zeros the first time it runs anywhere else — the same silent wrong
        # answer this framework turns into a sentence wherever it can.
        #
        # A warning and not an error: a game may read the time where nobody sees it (a seed for
        # its random numbers), and zeros there do no harm. It names the first line that reads it.
        class ClockNeverAsked
          NAME = :clock_never_asked
          PLAIN_NAME = "the time read without asking for a clock"

          def detect(program)
            readings = program.walk.select { |node| node.kind == :clock }
            time = readings.find { |node| Clock::TIME.include?(node.reading) }
            return [] unless time && readings.none? { |node| Clock::QUESTIONS.include?(node.reading) }

            [Finding.new(check: NAME, severity: :warning, message: MESSAGE, node: statement_with_line(time))]
          end

          MESSAGE = "This game reads the time from `clock`, but it does not ask `clock.present?` or " \
                    "`clock.set?`. Most emulators give a cartridge no clock unless you tell them to. A clock " \
                    "with a dead battery was never set. If there is no clock, or the clock was never set, " \
                    "every reading is 0, and the game shows 0 for the time. To fix this, ask " \
                    "`clock.present?` and `clock.set?` before you show the time. If either one is false, " \
                    "tell the player."

          private

          # The statement the reading is part of, which is the node the builder gave a line.
          def statement_with_line(node)
            node = node.parent while node.source.nil? && node.parent
            node
          end
        end
      end
    end
  end
end
