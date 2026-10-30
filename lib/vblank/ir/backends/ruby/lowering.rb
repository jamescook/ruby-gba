# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Ruby
        # ONE PROGRAM, WRITTEN OUT AS RUBY. Make one per program and ask for #text_and_gaps.
        #
        # The program is built as a tree of statements — globals, routines, tables of numbers,
        # and calls into a runtime, never an operator on a number — by the native lowering this
        # inherits, so what a program says (which kinds are refused, which art is worked out in
        # Ruby while building) is decided in one place; Printer writes that tree as Ruby.
        class Lowering < Native::Lowering
          # The program as the body of the game's class, and the runtime functions it calls that
          # the runtime it is to run with does not have yet (+runtime_functions+, the functions of
          # the runtime and the driver it is put together with), each said in a few words.
          def text_and_gaps(runtime_functions)
            refuse_unlowered_kinds!
            items = top_level
            printer = Printer.new
            text = printer.print_file(items)
            [text, runtime_gaps(items, printer.called, runtime_functions)]
          end

          # THE CONSOLE THE GAME IS PLAYED AS, in the numbers the runtime needs from it, as the
          # first lines of the game's class, so the runtime keeps none of any one console's and
          # reads each as a constant: the size of its screen, the cycles its clock counts a second,
          # the cycles a frame lasts, and whether its cartridge's clock keeps the date. A frame's
          # share of a second is what decides how many samples of sound a frame makes, and how far
          # the cartridge's clock moves on. The names and numbers are the C and JavaScript
          # runtimes' (Native::ConsoleNumbers), with true and false kept as Ruby's own.
          def console_text
            Native::ConsoleNumbers.values(@program.described_console).map { |name, value| "#{name} = #{value}\n" }.join
          end

          private

          def build_name = "the Ruby build"

          # WHAT THE RUNTIME CANNOT DO YET, found before the game is played rather than part way
          # through it: every function the printed game calls that is neither the runtime's nor
          # one of the game's own routines (Ruby::HEADLESS_FUNCTIONS and LIVE_FUNCTIONS say what
          # each has). Empty once the runtime is whole. In the order they first appear in the
          # printed program, and the first is the one a test that skips is counted under.
          def runtime_gaps(items, called, runtime_functions)
            own = items.grep(Native::C::Function).map { |function| function.name.text }
            called.to_a - own - runtime_functions
          end
        end
      end
    end
  end
end
