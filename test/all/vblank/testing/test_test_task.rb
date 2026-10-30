# frozen_string_literal: true

require "test_helper"
require "vblank/testing/test_task"

# What a game's Rakefile is told when it asks a test task for something it cannot be. Each case
# makes its task in a rake application of its own, so nothing reaches any other.
class TestTestTask < Minitest::Test
  # Rake keeps the application tasks are defined in as one value for the whole process, and a
  # case here puts its own in place for a moment; the YJIT cases also change the process's
  # environment and start a run of their own. So on the main Ractor, not in the pool.
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
    assert_match(/:gba, :native, :js, :ruby, :gbc or :snes/, error.message)
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

  # YJIT slows a run in Ractors down rather than speeding it up, so such a run is played without
  # it even when the Ruby options ask for it.
  def test_a_run_in_ractors_is_played_without_yjit_even_when_asked_for
    assert_equal "false", yjit_in_a_run_of(:gba, test_options: "--ractor", ruby_options: "--yjit")
  end

  def test_a_gba_run_without_ractors_is_played_with_yjit
    assert_equal "true", yjit_in_a_run_of(:gba, test_options: nil)
  end

  def test_a_run_yjit_speeds_up_is_played_with_it
    assert_equal "true", yjit_in_a_run_of(:js, test_options: nil)
  end

  def test_a_run_yjit_slows_down_is_played_without_it
    assert_equal "false", yjit_in_a_run_of(:gbc, test_options: nil, ruby_options: "--yjit")
  end

  # Plays a run of +lowering+ over one file that writes down whether YJIT is on in the Ruby
  # playing it. +ruby_options+ stands for whatever YJIT switch the caller's RUBYOPT has.
  private def yjit_in_a_run_of(lowering, test_options:, ruby_options: nil)
    skip "This Ruby is built without YJIT." unless defined?(RubyVM::YJIT)

    Dir.mktmpdir do |dir|
      record = File.join(dir, "yjit")
      probe = File.join(dir, "probe.rb")
      File.write(probe, "File.write(#{record.inspect}, RubyVM::YJIT.enabled?.to_s)\n")
      # TEST and TESTOPTS name the outer run's files and options, which rake's task would take
      # over its own.
      their_options = ENV.fetch("RUBYOPT", "").split.grep_v(/yjit/)
      with_environment("TEST" => nil, "TESTOPTS" => test_options, "RUBY_YJIT_ENABLE" => nil,
                       "RUBYOPT" => [*their_options, ruby_options].compact.join(" ")) do
        Rake.with_application(Rake::Application.new) do
          TestTask.new(:walking) do |t|
            t.lowering = lowering
            t.test_files = [probe]
          end
          Rake::Task[:walking].invoke
        end
      end
      File.read(record)
    end
  end

  private def with_environment(settings)
    was = settings.keys.to_h { |name| [name, ENV.fetch(name, nil)] }
    settings.each { |name, value| ENV[name] = value }
    yield
  ensure
    was.each { |name, value| ENV[name] = value }
  end
end
