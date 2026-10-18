# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class JS
        # ONE PROGRAM, WRITTEN OUT AS JAVASCRIPT. Make one per program and ask for #source.
        #
        # It is the native lowering's own, printed another way. Native::Lowering turns a program
        # into a small tree of statements (Native::C): globals, routines, tables of numbers, and
        # calls into a runtime — never an operator on a number, since every one goes through a
        # function that does what IR::Int32 does. Nothing in that tree is C's alone, so the same
        # tree is printed as JavaScript here (Printer) and played by a runtime written in
        # JavaScript (runtime/), which is the native runtime's C function for function. The
        # STATEMENTS and VALUES tables, the art worked out in Ruby, which kinds it cannot write
        # yet, what it refuses — a console-only step the program can reach, and only that: all of
        # that is the native lowering's, so the two can never disagree about what a program says,
        # only about how a runtime does it — and each runtime is checked against the interpreter
        # on its own.
        #
        # What differs is said here: the build a refusal names. The guardrail that tells an
        # author about a console-only step before a web build is Guardrails::Checks::WebPortability.
        class Lowering < Native::Lowering
          # The program as one JavaScript file's text: the game alone, with no runtime (see
          # JS#bundle for a program that runs).
          def source
            refuse_unlowered_kinds!
            Printer.new.print_file(top_level)
          end

          private

          def build_name = "the browser build"
        end
      end
    end
  end
end
