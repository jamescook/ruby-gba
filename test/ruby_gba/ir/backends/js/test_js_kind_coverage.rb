# frozen_string_literal: true

require "test_helper"
require "conformance_fixture"

# Every runtime function a game written as JavaScript calls is one the JavaScript runtime defines.
# Which kinds are written at all is the native lowering's to say (JS::Lowering inherits its
# tables, and test_native_kind_coverage.rb holds them); what only this lowering can get wrong is a
# runtime with a function missing.
class TestJSKindCoverage < Minitest::Test
  JS = RubyGBA::IR::Backends::JS

  # The kitchen-sink fixture touches every kind, so its JavaScript calls everything a game can
  # call; a name the native runtime has and this one lacks would only be found by a game that
  # happened to use it.
  def test_every_runtime_function_a_game_calls_is_defined
    source = JS.new.lower(ConformanceFixture.program)
    called = source.scan(/\b(rg_[a-z0-9_]+)\(/).flatten.uniq.reject { |name| name.start_with?("rg_game_") }
    runtime = JS::RUNTIME.map { |file| File.read(File.join(JS::RUNTIME_DIR, file), encoding: Encoding::UTF_8) }.join
    defined = runtime.scan(/^function\*? (rg_[a-z0-9_]+)\(/).flatten

    assert_empty called - defined
  end
end
