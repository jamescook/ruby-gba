# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # THE LAYERS A SCREEN CANNOT HAVE, asked by the interpreter and by each console's lowering as
        # well as by the build: more backgrounds than the console stacks, more than one status bar,
        # and a status bar beside something that needs the same part of the display. A program handed
        # straight to a backend never passes the build's checks, so each backend asks these itself,
        # and all of them stop with the same words.
        module LayerRefusals
          CHECKS = [TooManyBackgroundLayers, TooManyStatusBars, StatusBarCannotShare].freeze

          module_function

          # The first refusal's message, or nil when the layers fit.
          def message(program)
            CHECKS.each do |check|
              found = check.new.refusal_message(program)
              return found if found
            end
            nil
          end
        end
      end
    end
  end
end
