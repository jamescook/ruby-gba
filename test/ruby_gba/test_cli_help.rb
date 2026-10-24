# frozen_string_literal: true

require "test_helper"

require "open3"
require "tmpdir"
require "rbconfig"

# What `ruby-gba` says when somebody asks it how to use it, or uses it wrong: the help for each
# command, the list of commands, and what an option it does not know gets back. Run as a person
# runs it, in a process of its own.
class TestCLIHelp < Minitest::Test
  # Every test starts the command as a child process, which Ruby cannot do from inside a Ractor.
  runs_on_the_main_ractor!

  # Which Ruby to launch, asked once here: a worker may not read Ruby's own build table.
  RUBY = RbConfig.ruby.freeze
  BIN = RubyGBA.root.join("bin/ruby-gba").to_s

  COMMANDS = %w[build profile play compare preview inspect new].freeze
  HELP_FLAGS = %w[--help -h].freeze
  WIDTH = 80

  private def cli(*args, dir: Dir.pwd)
    Open3.capture2e(RUBY, BIN, *args, chdir: dir)
  end

  private def assert_fits(text, what)
    wide = text.lines.map(&:chomp).select { |line| line.length > WIDTH }
    assert_empty wide, "#{what} has lines wider than #{WIDTH} columns"
  end

  def test_every_command_answers_help_the_same_three_ways
    COMMANDS.each do |command|
      asked, status = cli("help", command)
      assert status.success?, asked
      assert_match(/\AUsage: ruby-gba #{command} /, asked, "#{command}'s help starts with how to write it")
      assert_fits asked, "ruby-gba help #{command}"

      HELP_FLAGS.each do |flag|
        out, status = cli(command, flag)
        assert status.success?, "ruby-gba #{command} #{flag} failed:\n#{out}"
        assert_equal asked, out, "ruby-gba #{command} #{flag} prints the same help as ruby-gba help #{command}"
      end
    end
  end

  # A help flag anywhere on the line is a request for help, not a file name or an option value.
  def test_a_help_flag_after_the_game_file_still_asks_for_help
    asked, = cli("help", "build")
    out, status = cli("build", "game.rb", "--help")

    assert status.success?, out
    assert_equal asked, out
  end

  # The builds people want come first, written the way they work: the game file goes before any
  # option that takes several words, since those take every word after them.
  def test_build_help_starts_with_the_builds_people_want
    out, = cli("help", "build")
    examples = out.index("ruby-gba build game.rb --format=native")

    refute_nil examples, "a desktop build is one of the examples:\n#{out}"
    assert_operator examples, :<, out.index("Options"), "the examples come before the options"
    assert_match(/^  ruby-gba build game.rb +a .gba cartridge/, out)
    assert_includes out, "ruby-gba build game.rb --format=web"
    assert_includes out, "ruby-gba build game.rb -o "
    assert_match(/\AUsage: ruby-gba build GAME_FILE \[--format game\|native\|web\]/, out, "the usage line names the formats")
  end

  def test_a_command_that_is_not_there_names_the_ones_that_are
    [%w[biuld], %w[biuld --help], %w[help biuld], %w[tree]].each do |args|
      out, status = cli(*args)

      refute status.success?, "ruby-gba #{args.join(' ')}"
      assert_match(/There is no command "#{args.last == '--help' ? args.first : args.last}"/, out)
      assert_includes out, "build", "and it lists the commands"
    end
  end

  def test_help_about_help_is_the_command_list
    listed, = cli("help")

    assert_equal listed, cli("help", "help").first
  end

  # An option that needs a value and is given none would otherwise take its own name as the
  # value: -o alone wrote a file called "output".
  def test_an_option_given_no_value_is_refused
    out, status = cli("build", "game.rb", "-o")

    refute status.success?
    assert_match(/-o needs a value/, out)
  end

  # ...and a value that starts with a dash is a value, not an option.
  def test_a_value_that_starts_with_a_dash_is_not_taken_for_an_option
    out, = cli("build", "game.rb", "-o", "-odd.gba")

    refute_includes out, "has no option"
    assert_includes out, "cannot find the game file game.rb"
  end

  def test_two_game_files_say_build_takes_one
    out, status = cli("build", "one.rb", "two.rb")

    refute status.success?
    assert_includes out, "ruby-gba build takes one GAME_FILE"
  end

  # An option that takes several words takes the game file too, when the file comes after it.
  def test_a_game_file_taken_by_set_says_so
    out, status = cli("build", "--set", "floors=3", "game.rb")

    refute status.success?
    assert_includes out, "--set took game.rb"
    assert_includes out, "ruby-gba build game.rb --set floors=3"
  end

  def test_an_unknown_build_option_names_the_formats
    out, = cli("build", "game.rb", "--bogus")

    assert_includes out, "--format game, native or web"
  end

  def test_the_command_list_names_every_command_and_cuts_no_words
    listed, status = cli("help")
    assert status.success?, listed
    assert_fits listed, "ruby-gba help"
    refute_includes listed, "...", "no description is cut short"
    COMMANDS.each { |command| assert_match(/^  ruby-gba #{command}\b/, listed) }

    [[], ["--help"], ["-h"]].each do |args|
      out, = cli(*args)
      assert_equal listed, out, "ruby-gba #{args.join(' ')} prints the same list"
    end
  end

  # A misspelled option used to be taken as a file name, or dropped without a word, so a build
  # asked for as a web page came out a cartridge.
  def test_an_option_a_command_does_not_have_is_refused_by_name
    out, status = cli("build", "game.rb", "--fromat=web")

    refute status.success?
    assert_includes out, "--fromat"
    assert_includes out, "--format", "it says which option was meant"
    assert_includes out, "ruby-gba build --help"
    refute_match(/\.rb:\d+:in/, out, "no backtrace")
  end

  def test_a_command_given_no_file_says_how_it_is_written
    out, status = cli("build")

    refute status.success?
    assert_includes out, "ruby-gba build GAME_FILE"
    assert_includes out, "ruby-gba build --help"
    refute_includes out, "was called with", "not Thor's own words"
  end

  def test_native_desktop_and_web_say_how_they_are_written
    {
      "--native" => "ruby-gba build game.rb --format=native",
      "--desktop" => "ruby-gba build game.rb --format=native",
      "--web" => "ruby-gba build game.rb --format=web"
    }.each do |given, meant|
      out, status = cli("build", "game.rb", given)

      refute status.success?, "#{given} is not an option"
      assert_includes out, meant, "#{given} says the line to write instead"
    end
  end
end
