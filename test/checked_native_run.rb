# frozen_string_literal: true

require "native_comparison"

# What `game_player` hands a test on a native run: the library's checked run (Native::CheckedRun,
# which says what it compares), with a disagreement reported as a failed test rather than as an
# error, the way every other check in the suite fails.
class CheckedNativeRun < RubyGBA::IR::Backends::Native::CheckedRun
  def run(program, max_steps: nil, frames: nil)
    super
  rescue Disagreement => e
    raise Minitest::Assertion, e.message
  end
end
