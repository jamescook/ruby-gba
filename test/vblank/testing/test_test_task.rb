# frozen_string_literal: true

require "test_helper"
require "vblank/testing/test_task"

# What a game's Rakefile is told when it asks a test task for something it cannot be. Each case
# makes its task in a rake application of its own, so nothing reaches any other.
class TestTestTask < Minitest::Test
  # Rake keeps the application tasks are defined in as one value for the whole process, and a
  # case here puts its own in place for a moment, so on the main Ractor, not in the pool.
  runs_on_the_main_ractor!

  TestTask = VBlank::Testing::TestTask

  private def made_alone(&)
    task = nil
    Rake.with_application(Rake::Application.new) { task = TestTask.new(:walking, &) }
    task
  end

  def test_a_lowering_there_is_not_is_refused_naming_the_ones_there_are
    error = assert_raises(ArgumentError) { made_alone { |t| t.lowering = "native" } }

    assert_match(/was given "native"/, error.message)
    assert_match(/:gba, :native, :js or :gbc/, error.message)
  end

  # The process runner is loaded into a native run as the task is made, so a lowering said
  # afterwards would make a run that is neither.
  def test_a_lowering_said_after_the_task_is_made_is_refused
    task = made_alone { |t| t.test_files = [] }

    error = assert_raises(ArgumentError) { task.lowering = :native }

    assert_match(/inside the block/, error.message)
  end

  def test_a_task_is_for_the_gba_lowering_unless_told
    assert_equal :gba, made_alone { |t| t.test_files = [] }.lowering
  end
end
