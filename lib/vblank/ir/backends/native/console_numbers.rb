# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # THE CONSOLE THE C IS BUILT AS, written where the runtime reads it: rg_console_numbers.h,
        # beside game.c, which runtime/rg_console.h includes. Its screen is the size of the
        # runtime's buffers and window, and its clock says how long a frame lasts. Everything else
        # the game does differently on one console than another is decided when the game is
        # lowered, from the same description.
        module ConsoleNumbers
          FILE = "rg_console_numbers.h"

          module_function

          # The header for +console+ (a Console::Description).
          def header(console)
            <<~C
              /* Written by Native::ConsoleNumbers: the #{console.title}. */
              #define RG_SCREEN_WIDTH #{console.screen_width}
              #define RG_SCREEN_HEIGHT #{console.screen_height}
              #define RG_CONSOLE_TICKS_A_SECOND #{console.cycles_a_second}
              #define RG_CONSOLE_TICKS_A_FRAME #{console.cycles_a_frame}
              #define RG_CONSOLE_BLENDS #{console.blends ? 1 : 0}
              #define RG_CONSOLE_RUMBLES #{console.rumbles ? 1 : 0}
              #define RG_CLOCK_KEEPS_DATE #{console.clock_keeps_date ? 1 : 0}
            C
          end
        end
      end
    end
  end
end
