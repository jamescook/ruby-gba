# frozen_string_literal: true

module RubyGBA
  module Testing
    # What a test's player is on the native lowering's run: the game played as C and checked
    # against the interpreter on every frame (Native::CheckedRun says what it compares), with a
    # disagreement reported as a failed test rather than as an error, the way every other check
    # in a suite fails.
    class CheckedPlayer < IR::Backends::Native::CheckedRun
      def run(program, max_steps: nil, frames: nil)
        super
      rescue Disagreement => e
        raise Minitest::Assertion, e.message
      end
    end

    # The same, on the JavaScript lowering's run: the game played as JavaScript under node
    # (JS::CheckedRun), checked against the interpreter on every frame by the same check.
    class JSCheckedPlayer < IR::Backends::JS::CheckedRun
      def run(program, max_steps: nil, frames: nil)
        super
      rescue Disagreement => e
        raise Minitest::Assertion, e.message
      end
    end
  end
end
