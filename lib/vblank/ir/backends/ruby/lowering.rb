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
          # the Ruby runtime does not have yet, each said in a few words (see #runtime_gaps).
          def text_and_gaps
            refuse_unlowered_kinds!
            items = top_level
            printer = Printer.new
            text = printer.print_file(items)
            [text, runtime_gaps(items, printer.called)]
          end

          private

          def build_name = "the Ruby build"

          # WHAT THE RUNTIME CANNOT DO YET, found before the game is played rather than part way
          # through it: every function the printed game calls that is neither the runtime's nor
          # one of the game's own routines, and a game that mixes recordings, which the runtime's
          # frame does on its own (Ruby::RUNTIME_FUNCTIONS says what the runtime has). Empty once
          # the runtime is whole. In the order they first appear in the printed program, and the
          # first is the one a test that skips is counted under.
          def runtime_gaps(items, called)
            own = items.grep(Native::C::Function).map { |function| function.name.text }
            gaps = called.to_a - own - RUNTIME_FUNCTIONS
            mix = items.find { |item| item.is_a?(Native::C::ConstArray) && item.name.text == "rg_game_mix" }
            gaps << "mixing recordings" if mix && mix.values.first != 0
            gaps
          end
        end
      end
    end
  end
end
