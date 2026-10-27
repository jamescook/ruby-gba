# frozen_string_literal: true

module VBlank
  module Testing
    # A checked run's disagreement with the interpreter reported as a failed test rather than as
    # an error, the way every other check in a suite fails.
    module DisagreementFailsTest
      def run(program, max_steps: nil, frames: nil)
        super
      rescue IR::Backends::RunComparison::Disagreement => e
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

    # The same, on the Ruby lowering's run: the game played as Ruby (Ruby::CheckedRun), checked
    # against the interpreter on every frame by the same check. What its runtime cannot do yet is a
    # skip naming it, so the run's count of skips by reason says what is left to do.
    class RubyCheckedPlayer < IR::Backends::Ruby::CheckedRun
      include DisagreementFailsTest

      def run(program, max_steps: nil, frames: nil)
        super
      rescue IR::Backends::Ruby::RuntimeGap => e
        raise Minitest::Skip, gap_reason(e)
      end

      # What the runtime cannot do yet a test asks of the run before or after it, a skip too.
      def method_missing(name, ...)
        super
      rescue IR::Backends::Ruby::RuntimeGap => e
        raise Minitest::Skip, gap_reason(e)
      end

      def respond_to_missing?(name, include_private = false) = super

      private

      def gap_reason(gap) = "Ruby's runtime does not have yet: #{gap.part}"
    end

    # The same, on the Game Boy Color lowering's run: the game built as a Game Boy Color cartridge
    # and played in the emulator (GBC::CheckedRun), checked against the interpreter after every
    # pass, each test's program played as a Color program. A test of what the Color's hardware
    # cannot do is not here to play at all: it lives with the Advance's tests, which this run
    # never loads (TestSuites::ADVANCE_DIR in this repository). What the Color's build does not make
    # yet fails, since it is still to be made; what the run cannot answer of it is a skip.
    class GBCCheckedPlayer < IR::Backends::GBC::CheckedRun
      include DisagreementFailsTest

      # +program+ as this run plays it: one that names no console, as a Color program.
      def self.program_played(program)
        return program unless program.kind == :program && program.console.nil?

        program.copy.tap { |copy| copy.console = :gbc }
      end

      def run(program, max_steps: nil, frames: nil)
        program = self.class.program_played(program)
        super
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
    end
  end
end
