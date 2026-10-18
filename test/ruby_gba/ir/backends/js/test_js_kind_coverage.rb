# frozen_string_literal: true

require "test_helper"
require "conformance_fixture"

# Every kind of node a browser build could meet is either written as JavaScript or on the list of
# kinds the lowering cannot write yet — never neither, and never both. The statements are the
# native lowering's, so the two lists are its lists; what this holds is that the JavaScript
# lowering reads them, and that the runtime has a function for every call those statements make.
class TestJSKindCoverage < Minitest::Test
  Nodes = RubyGBA::IR::Nodes
  Portability = RubyGBA::IR::Portability
  JS = RubyGBA::IR::Backends::JS
  Lowering = JS::Lowering

  private def portable_kinds
    (Nodes.of_role(:statement) + Nodes.of_role(:value) + Nodes.of_role(:declaration))
      .reject { |kind| Portability.hardware_only?(kind) }
  end

  private def handled = Lowering::STATEMENTS.keys + Lowering::VALUES.keys
  private def not_yet = Lowering::NOT_LOWERED_YET.values.flatten

  def test_every_kind_is_written_as_javascript_or_listed_as_not_yet
    assert_empty portable_kinds - handled - not_yet
  end

  def test_a_kind_written_as_javascript_is_off_the_not_yet_list
    assert_empty handled & not_yet
  end

  # Every runtime function the game calls is one the JavaScript runtime defines. The kitchen-sink
  # fixture touches every kind, so its JavaScript calls everything a game can call; a name the
  # native runtime has and this one lacks would only be found by a game that happened to use it.
  def test_every_runtime_function_a_game_calls_is_defined
    source = JS.new.lower(ConformanceFixture.program)
    called = source.scan(/\b(rg_[a-z0-9_]+)\(/).flatten.uniq.reject { |name| name.start_with?("rg_game_") }
    runtime = JS::RUNTIME.map { |file| File.read(File.join(JS::RUNTIME_DIR, file), encoding: Encoding::UTF_8) }.join
    defined = runtime.scan(/^function\*? (rg_[a-z0-9_]+)\(/).flatten

    assert_empty called - defined
  end
end
