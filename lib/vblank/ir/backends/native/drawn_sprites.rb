# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # WHICH SPRITES A GAME DREW, as the C prints it (runtime/rg_headless.c) and as a test reads
        # it: a line for each row, "sprite" and four numbers — whose, which picture, and where —
        # numbered by SpriteNames (RG_NO_NAME is SpriteNames::NO_NAME).
        class DrawnSprites < SpriteNames
          # The rows printed among +lines+, in the order they were drawn: back to front.
          def rows_in(lines) = lines.grep(/\Asprite /).map { |line| row_from(line) }

          # One printed line read as the interpreter's row.
          def row_from(line) = row(*line.delete_prefix("sprite ").split(" ").map { |number| Integer(number) })
        end
      end
    end
  end
end
