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
        #
        # The JavaScript and Ruby runtimes are handed the same numbers by the same names
        # (JS#console_text, Ruby::Lowering#console_text), each from #values, so a new one is
        # added here once and reaches all three.
        module ConsoleNumbers
          FILE = "rg_console_numbers.h"

          module_function

          # What the runtimes are told of +console+ (a Console::Description), by the name each
          # reads it as: numbers, and true or false for what the console does or does not do.
          def values(console)
            { "RG_SCREEN_WIDTH" => console.screen_width, "RG_SCREEN_HEIGHT" => console.screen_height,
              "RG_CONSOLE_TICKS_A_SECOND" => console.cycles_a_second,
              "RG_CONSOLE_TICKS_A_FRAME" => console.cycles_a_frame,
              "RG_CONSOLE_BLENDS" => console.blends, "RG_CONSOLE_RUMBLES" => console.rumbles,
              "RG_CLOCK_KEEPS_DATE" => console.clock_keeps_date }
          end

          # +value+ as C and JavaScript write it: true and false as 1 and 0.
          def as_number(value) = { true => 1, false => 0 }.fetch(value, value)

          # The header for +console+.
          def header(console)
            defines = values(console).map { |name, value| "#define #{name} #{as_number(value)}\n" }
            "/* Written by Native::ConsoleNumbers: the #{console.title}. */\n#{defines.join}"
          end
        end
      end
    end
  end
end
