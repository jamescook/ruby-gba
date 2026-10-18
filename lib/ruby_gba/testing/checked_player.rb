# frozen_string_literal: true

module RubyGBA
  module Testing
    # A checked run's disagreement with the interpreter reported as a failed test rather than as
    # an error, the way every other check in a suite fails.
    module DisagreementFailsTest
      def run(program, max_steps: nil, frames: nil)
        super
      rescue IR::Backends::Native::CheckedRun::Disagreement, IR::Backends::GBC::CheckedRun::Disagreement => e
        raise Minitest::Assertion, e.message
      end
    end

    # What a test's player is on the native lowering's run: the game played as C and checked
    # against the interpreter on every frame (Native::CheckedRun says what it compares).
    class CheckedPlayer < IR::Backends::Native::CheckedRun
      include DisagreementFailsTest
    end

    # The same, on the JavaScript lowering's run: the game played as JavaScript under node
    # (JS::CheckedRun), checked against the interpreter on every frame by the same check.
    class JSCheckedPlayer < IR::Backends::JS::CheckedRun
      include DisagreementFailsTest
    end

    # The same, on the Game Boy Color lowering's run: the game built as a Game Boy Color cartridge
    # and played in the emulator (GBC::CheckedRun), checked against the interpreter after every
    # pass. A game the Color cannot play is a skip saying why, counted with the run's skips by
    # reason — a game laid out for the Advance's larger screen that draws on it, a verb the Color
    # refuses, one it does not do yet — rather than a failure: those are answers, not faults.
    class GBCCheckedPlayer < IR::Backends::GBC::CheckedRun
      include DisagreementFailsTest

      def run(program, max_steps: nil, frames: nil)
        refuse_advance_picture!(program)
        super
      rescue IR::Backends::GBC::LoweringError => e
        raise Minitest::Skip, "Game Boy Color: #{reason_not_made(e.message)}"
      rescue IR::Backends::GBC::HeadlessRun::CannotAnswer => e
        raise Minitest::Skip, cannot_answer_reason(e)
      end

      # What the cartridge cannot answer yet a test asks of it after its run, a skip too.
      def method_missing(name, ...)
        super
      rescue IR::Backends::GBC::HeadlessRun::CannotAnswer => e
        raise Minitest::Skip, cannot_answer_reason(e)
      end

      def respond_to_missing?(name, include_private = false) = super

      private

      def cannot_answer_reason(error) = "Game Boy Color cannot answer: #{error.message[/`(\w+\??)`/, 1] || error.message}"

      # What a refusal says, short enough to count skips by: the parts of the picture or sound not
      # made yet, which the refusal names in brackets, or the refusal itself.
      def reason_not_made(message) = message[/cannot make yet \((.*)\)/, 1]&.then { |parts| "not made yet: #{parts}" } || message

      # A program built for the Advance that draws, drawn on the Color's smaller screen, is not the
      # game its test was written about.
      def refuse_advance_picture!(program)
        return if program.console == :gbc
        return unless program.walk.any? { |node| node.category == :draw }

        raise Minitest::Skip, "Game Boy Color: the game is laid out for the Advance's screen"
      end
    end
  end
end
