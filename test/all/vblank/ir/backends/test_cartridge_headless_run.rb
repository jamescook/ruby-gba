# frozen_string_literal: true

require "test_helper"

# The stand-ins a test is handed on the run of a console whose own cartridge is played, in place of
# the interpreter (CartridgeHeadlessRun, and each console's run on top of it).
class TestCartridgeHeadlessRun < Minitest::Test
  RUNS = VBlank::Console.kits.grep(VBlank::Console::CheckedKit).map { |kit| kit.lowering::HeadlessRun }.freeze

  # Every question a test can ask the interpreter is one each console's run has a method for, an
  # answer or a refusal by name, so none of them meets a bare NoMethodError.
  def test_every_question_the_interpreter_answers_has_a_method_on_each_consoles_run
    RUNS.each do |run|
      unanswered = Reference.public_instance_methods.reject { |name| run.public_method_defined?(name) }

      assert_empty unanswered, "give #{run} a method for each, `refuses` if nothing else"
    end
  end

  def test_each_consoles_run_is_one_of_the_cartridge_runs
    refute_empty RUNS

    RUNS.each { |run| assert_operator run, :<, VBlank::IR::Backends::CartridgeHeadlessRun }
  end

  # A question refused by name says which console's run refused it, and how to skip there.
  def test_a_refused_question_names_the_console_and_its_skip
    RUNS.each do |run|
      error = assert_raises(VBlank::IR::Backends::RunComparison::CannotAnswer) { run.new.frames_each_pass { 2 } }

      assert_match(/frames_each_pass/, error.message)
      assert_match(/skip_on_(gbc|snes)/, error.message)
    end
  end
end
