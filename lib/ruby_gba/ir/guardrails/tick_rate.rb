# frozen_string_literal: true

require_relative "../cost_model"

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # A timer asks the console to interrupt the game a fixed number of times a second, and
        # the handler has until the next tick to finish. It is not a queue: a tick that arrives
        # while the last one is still being answered is simply LOST. So a handler that outruns
        # the gap between ticks answers every second tick, or every third, and the game quietly
        # runs at a fraction of the rate its author wrote down.
        #
        # Nothing says so. There is no crash and no glitch — a music sequencer just plays at
        # half speed, a sampled voice drops to half its pitch, a physics step takes twice as
        # long as it was meant to. And the rate is written on the `timer`, often far from the
        # handler, so the two numbers that decide it are never on screen together.
        #
        # Measured on the console: a handler of eighty statements at 30,000 ticks a second
        # delivers exactly half of them; the same handler at 4,000 delivers all of them.
        #
        # This is advisory, not an error. A game may genuinely want "as often as possible" and
        # get it, and the estimate that decides this is an estimate — so the build carries on
        # and the message says the rate that fits.
        class TickRate
          NAME = :tick_rate
          PLAIN_NAME = "a tick rate too fast to deliver"

          # Takes the cost model rather than building one. Whether the handler runs from the
          # console's quick memory decides most of what it costs — code kept there is about
          # two and a half times faster — and that is the build's answer, not something to
          # assume. This check used to assume the best case (fast_interrupts: true) because it
          # ran before the build had decided; now it runs after and asks. See
          # Guardrails.build_checks.
          def initialize(model)
            @model = model
          end

          def detect(program)
            verdict = @model.tick_verdict(program) or return []

            verdict.timers.select { |timer| timer.delivered < timer.hz }.map do |timer|
              Finding.new(check: NAME, severity: :warning, message: message_for(timer),
                          node: handler_for(program, timer.name))
            end
          end

          private

          # The `on_tick` node itself, so the finding points at the handler rather than at the
          # `timer` line: the rate is what has to change, but the body is what makes it too
          # much, and the body is what an author reads to see why.
          def handler_for(program, name)
            program.walk.find { |node| node.kind == :on_timer && node.timer == name }
          end

          def message_for(timer)
            "The :#{timer.name} timer asks for #{timer.hz} ticks a second. Its handler is " \
              "too long to finish between two ticks. So the console loses the ticks that " \
              "arrive while it runs, and the handler gets about #{timer.delivered.round} a " \
              "second. To fix this, set `per_second: #{timer.delivered.round}` or less. Or " \
              "make the handler shorter: move work into the game loop, which has a whole " \
              "frame to do it in."
          end
        end
      end
    end
  end
end
