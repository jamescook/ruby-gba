# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class JS
        # A game run as JavaScript with no window (runtime/rg_headless.js, played by node), driven
        # and read back through the calls a test makes on Backends::Reference.
        #
        # The windowless JavaScript program prints exactly what the native one prints, line for
        # line, so everything about reading it — the variables, the lists, the picture file, the
        # sprites, the sound log, the mixer — is Native::HeadlessRun's, and only the program it
        # plays is this one's.
        class HeadlessRun < Native::HeadlessRun
          # Raised for something a test asks of the interpreter that the JavaScript lowering cannot
          # answer yet. The native one's, since both are asked the same questions.
          CannotAnswer = Native::HeadlessRun::CannotAnswer

          # The browser build has no clock yet: its runtime answers every reading as a cartridge
          # with no clock chip does.
          def clock_at(*, **) = refuse_unanswered!(:clock_at)

          private

          def headless_program(program) = JS.new.build_headless(program)
          def lowering_name = "the JavaScript lowering"
          def skip_helper_name = "skip_on_js"
        end
      end
    end
  end
end
