# frozen_string_literal: true

require "test_helper"

# Each run of the suite tests ONE lowering — `rake test` the interpreter, `rake test:native` the
# game as C — and a test class runs only on the lowerings it names (`runs_on`). Every class has
# to name them: one that says nothing stops the run before a test is played. This class names the
# interpreter alone, so it fails if a native run ever picks it up. Its other side is
# test_native_suite.rb, which names only native and fails if `rake test` ever runs it.
class TestSuitesSplit < Minitest::Test
  runs_on :reference

  PLAYERS = [Reference, CheckedNativeRun, RubyGBA::IR::Backends::Native::HeadlessRun].freeze

  # A stand-in for a test class: what it is called, what it said to `runs_on` (nil for nothing),
  # and its methods.
  Stand = Struct.new(:name, :lowerings, :public_instance_methods)

  SILENT = Stand.new("TestSilent", nil, %i[test_something helper])
  HELPERS_ONLY = Stand.new("SharedSetup", nil, %i[setup helper])
  INTERPRETER = Stand.new("TestInterpreter", %i[reference], %i[test_a])
  BOTH = Stand.new("TestBoth", %i[reference native], %i[test_a])
  NATIVE = Stand.new("TestNative", %i[native], %i[test_a])

  def test_a_class_that_names_only_the_interpreter_runs_only_there
    assert_equal :reference, TestSuites::LOWERING,
                 "a test class that said `runs_on :reference` alone ran on a #{TestSuites::LOWERING} run"
  end

  # Saying nothing used to mean "the interpreter alone", which read the same whether native
  # could not play the tests yet or nobody had looked. Now it is a class nobody has decided
  # about, and it is found before the run starts.
  def test_a_class_with_tests_that_names_no_lowering_is_found
    assert_equal [SILENT], TestSuites.classes_naming_no_lowering([SILENT, HELPERS_ONLY, INTERPRETER, BOTH, NATIVE])
  end

  def test_the_run_is_refused_in_plain_words_naming_each_such_class
    message = TestSuites.unnamed_lowerings_message([SILENT, INTERPRETER])

    assert_match(/TestSilent/, message)
    assert_match(/runs_on :reference/, message)
    refute_match(/TestInterpreter/, message)
  end

  def test_nothing_is_refused_when_every_class_has_said
    assert_nil TestSuites.unnamed_lowerings_message([HELPERS_ONLY, INTERPRETER, BOTH, NATIVE])
  end

  # What a native run says at its end, so the classes it did not play are counted in plain sight.
  def test_the_classes_are_counted_by_where_they_run
    counts = TestSuites.classes_by_lowerings([INTERPRETER, INTERPRETER, BOTH, NATIVE, HELPERS_ONLY])

    assert_equal({ both: 1, native_only: 1, interpreter_only: 2 }, counts)
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
