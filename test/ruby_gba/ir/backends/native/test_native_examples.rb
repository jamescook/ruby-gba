# frozen_string_literal: true

require "test_helper"
require "open3"

# An example the native lowering can build is an example it is checked on. The lowering trails
# the other two, so examples become buildable one feature at a time, and nothing about a feature
# landing says "that example's tests can run as C now". This says it: for every example
# tools/native_examples.rb reports as building, there is a recorded run compared with the
# interpreter, and the example's own test file plays it through `game_player`.
class TestNativeExamples < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  ROOT = RubyGBA.root.to_s
  TOOL = File.join(ROOT, "tools", "native_examples.rb")
  RECORDED_RUNS = File.join(ROOT, "test", "ruby_gba", "ir", "backends", "native", "examples")
  EXAMPLE_TESTS = File.join(ROOT, "test", "examples")

  # The names of the examples that build, as the tool prints them: "name<tab>builds".
  private def examples_that_build
    printed, complaint, status = Open3.capture3(Gem.ruby, TOOL, chdir: ROOT)
    flunk "tools/native_examples.rb failed:\n#{complaint}" unless status.success?

    printed.lines(chomp: true).filter_map { |line| line.split("\t").then { |name, verdict| name if verdict == "builds" } }
  end

  def test_every_example_that_builds_has_a_recorded_run_compared_with_the_interpreter
    built = examples_that_build
    without = built.reject { |name| File.exist?(File.join(RECORDED_RUNS, "test_#{name}_picture.rb")) }

    assert_operator built.length, :>, 10, "the tool should find the examples that build"
    assert_empty without, "these examples build as C and have no recorded run in " \
                          "test/ruby_gba/ir/backends/native/examples/ (test_<example>_picture.rb)"
  end

  # A test file of such an example that still plays the game on the interpreter by name has been
  # left behind: it wants `runs_on :reference, :native` and `game_player`.
  def test_every_test_of_an_example_that_builds_plays_it_as_c_too
    built = examples_that_build
    left_behind = Dir.glob(File.join(EXAMPLE_TESTS, "test_*.rb")).select do |path|
      text = File.read(path)
      examples = text.scan(%r{require_relative "\.\./\.\./examples/(\w+)"}).flatten
      examples.any? && (examples - built).empty? && left_to_the_interpreter?(text)
    end

    assert_empty left_behind.map { |path| path.delete_prefix("#{ROOT}/") },
                 "these test files are of examples that build as C, and still play them on the interpreter " \
                 "alone: say `runs_on :reference, :native` and `game_player` in place of `Reference.new`"
  end

  private

  # A file that plays the game on the interpreter by name, or that asks for `game_player` in a
  # class the native run never plays. A file that does neither — its tests are all of the
  # cartridge, in the emulator — has nothing for the game as C to play, and is left alone.
  def left_to_the_interpreter?(text)
    text.include?("Reference.new") || (text.include?("game_player") && !text.match?(/^\s*runs_on :reference, :native\s*(#.*)?$/))
  end
end
