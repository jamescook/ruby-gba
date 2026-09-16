# frozen_string_literal: true

require "test_helper"

require "stringio"

# RubyGBA::Pager: page long text through the user's pager, the way `git diff` does,
# or print it straight through when there's nothing to page onto. The one thing that
# would make this awkward to test — actually shelling out to a real `less`, on a real
# terminal — is exactly what's dependency-injected away: +runner+ stands in for the
# subprocess, +out+ stands in for the terminal, +env+ stands in for ENV/PATH. No test
# here starts a real pager or needs a real TTY.
class TestPager < Minitest::Test
  # An out: double that claims to be an interactive terminal (a plain StringIO
  # doesn't define #tty? at all, which Pager already treats as "not interactive").
  class FakeTTY
    def initialize
      @written = +""
    end
    attr_reader :written

    def tty? = true
    def write(text) = @written << text
  end

  def test_pages_through_the_runner_when_output_is_a_terminal
    out = FakeTTY.new
    calls = []
    runner = ->(cmd, text) { calls << [cmd, text] }
    pager = RubyGBA::Pager.new(out: out, env: { "PAGER" => "the-pager" }, runner: runner)

    pager.page("hello\n")

    assert_equal [["the-pager", "hello\n"]], calls
    assert_empty out.written, "the runner is responsible for showing the text, not out.write"
  end

  def test_writes_straight_through_when_output_is_not_a_terminal
    out = StringIO.new
    calls = []
    pager = RubyGBA::Pager.new(out: out, env: { "PAGER" => "the-pager" }, runner: ->(*args) { calls << args })

    pager.page("hello\n")

    assert_equal "hello\n", out.string
    assert_empty calls, "a pipe or a captured test should never shell out"
  end

  def test_command_prefers_pager_env_var
    pager = RubyGBA::Pager.new(env: { "PAGER" => "most", "PATH" => "/usr/bin" })

    assert_equal "most", pager.command
  end

  def test_command_falls_back_to_less_when_it_is_on_the_path
    Dir.mktmpdir do |dir|
      less = File.join(dir, "less")
      File.write(less, "")
      File.chmod(0o755, less)
      pager = RubyGBA::Pager.new(env: { "PATH" => dir })

      assert_equal "less", pager.command
    end
  end

  def test_command_is_nil_when_pager_is_unset_and_less_is_not_on_the_path
    Dir.mktmpdir do |dir| # empty: nothing executable in it, least of all "less"
      pager = RubyGBA::Pager.new(env: { "PATH" => dir })

      assert_nil pager.command
    end
  end

  def test_command_treats_an_empty_pager_env_var_as_unset
    Dir.mktmpdir do |dir|
      pager = RubyGBA::Pager.new(env: { "PAGER" => "", "PATH" => dir })

      assert_nil pager.command
    end
  end

  # The default runner's own fallback — no pager command to run, so it prints
  # straight through — exercised directly (still no subprocess: a nil command
  # short-circuits before IO.popen is ever reached).
  def test_default_runner_writes_straight_through_when_there_is_no_pager
    out = FakeTTY.new
    pager = RubyGBA::Pager.new(out: out, env: { "PAGER" => "", "PATH" => "" })

    pager.page("hello\n")

    assert_equal "hello\n", out.written
  end
end
