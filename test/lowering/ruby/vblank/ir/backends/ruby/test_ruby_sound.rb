# frozen_string_literal: true

require "test_helper"
require "runtime_sounds"

# THE SOUND THE GAME AS RUBY MAKES, sample for sample against the native runtime's (see
# RuntimeSounds for what is played and why).
class TestRubySound < Minitest::Test
  include RuntimeSounds

  private def runtime_under_test = :ruby
end
