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
        # yet: all of that is the native lowering's, so the two can never disagree about what a
        # program says, only about how a runtime does it — and each runtime is checked against
        # the interpreter on its own.
        #
        # What differs is said here: the kinds a page in a browser cannot run, and the words a
        # refusal is put in.
        class Lowering < Native::Lowering
          # The program as one JavaScript file's text: the game alone, with no runtime (see
          # JS#bundle for a program that runs).
          def source
            refuse_unlowered_kinds!
            Printer.new.print_file(top_level)
          end

          private

          # A browser runs portable kinds only (IR::Portability says which those are; nothing here
          # lists them). What is refused is only what the program can REACH: a console-only step
          # in a routine nothing calls never runs, so the game plays the same without it, as it
          # does in the interpreter. The guardrail that says this to an author before a build is
          # Guardrails::WebPortability.
          def refuse_unlowered_kinds!
            hardware = @reachable.map(&:kind).uniq.select { |kind| Portability.hardware_only?(kind) }
            unless hardware.empty?
              raise LoweringError,
                    "this program uses #{hardware.map(&:inspect).join(', ')}, which only means something on " \
                    "the console itself, so it cannot be built for a browser."
            end

            super
          end

          def refuse_picture!(what)
            raise LoweringError, "this program uses #{what}, which the browser build cannot draw yet. " \
                                 "The cartridge build can."
          end
        end
      end
    end
  end
end
