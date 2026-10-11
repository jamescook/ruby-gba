# frozen_string_literal: true

require "test_helper"

# Each run of the suite tests ONE lowering — `rake test` the interpreter, `rake test:native` the
# game as C — and a test class runs only on the lowerings it names (`runs_on`). This class names
# none, which is every class that has not been looked at for native yet, so it fails if a native
# run ever picks it up. Its other side is test_native_suite.rb, which names only native and fails
# if `rake test` ever runs it.
class TestSuitesSplit < Minitest::Test
  PLAYERS = [Reference, CheckedNativeRun, RubyGBA::IR::Backends::Native::HeadlessRun].freeze

  def test_a_class_that_names_no_lowering_runs_only_on_the_interpreter
    assert_equal :reference, TestSuites::LOWERING,
                 "a test class that never said `runs_on :native` ran on a #{TestSuites::LOWERING} run"
  end

  # A test makes its player and runs a game the same way whichever lowering hands it the player,
  # so every player takes the interpreter's words. One added to the interpreter and not the
  # others fails here, on every `rake test`, rather than on the first native run that meets it.
  def test_every_player_takes_the_interpreters_words
    %i[initialize run].each do |method|
      words = PLAYERS.map { |player| [player, keywords_of(player.instance_method(method))] }

      assert_equal 1, words.map(&:last).uniq.size, "#{method} takes different words: #{words.to_h.inspect}"
    end
  end

  # On the interpreter's run the guard for a test native cannot play yet does nothing.
  def test_the_native_guard_lets_the_interpreter_run_through
    skip_on_native "only says something on a native run"
  rescue Minitest::Skip
    flunk "skip_on_native skipped a test on the interpreter's run"
  else
    pass
  end

  private

  def keywords_of(method) = method.parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }.sort
end
