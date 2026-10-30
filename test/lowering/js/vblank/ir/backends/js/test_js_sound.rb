# frozen_string_literal: true

require "test_helper"
require "runtime_sounds"

# THE SOUND THE GAME AS JAVASCRIPT MAKES, sample for sample against the native runtime's (see
# RuntimeSounds for what is played and why): what a web page's speaker would be handed.
class TestJSSound < Minitest::Test
  include RuntimeSounds

  private def runtime_under_test = :js
end
