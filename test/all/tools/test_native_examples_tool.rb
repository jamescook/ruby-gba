# frozen_string_literal: true

require "test_helper"
require "open3"

# tools/native_examples.rb says, for every example, whether the native lowering can write it as
# C today and what it is refused for when it cannot. Trying an example compiles nothing, so this
# runs on every `rake test`: what the list is USED for — holding an example that builds to
# having its tests played as C — is the native run's (test_native_examples.rb).
class TestNativeExamplesTool < Minitest::Test
  # Starts a child process, which Ruby cannot do from inside a Ractor — the spawn waits for
  # ever — so on the main Ractor, not in the pool. See test_helper.
  runs_on_the_main_ractor!

  ROOT = VBlank.root.to_s

  def test_it_says_of_every_example_that_it_builds_or_why_it_does_not
    printed, complaint, status = Open3.capture3(Gem.ruby, File.join(ROOT, "tools", "native_examples.rb"), chdir: ROOT)
    verdicts = printed.lines(chomp: true).to_h { |line| line.split("\t", 2) }
    examples = Dir.glob(File.join(ROOT, "examples", "*.rb")).map { |path| File.basename(path, ".rb") }

    assert_predicate status, :success?, complaint
    assert_equal examples.sort, verdicts.keys.sort
    assert_equal "builds", verdicts.fetch("pong")
    refuted = verdicts.reject { |_, verdict| verdict == "builds" }
    assert(refuted.each_value.all? { |why| why.match?(/desktop build|desktop program/) },
           "an example that does not build should say what the desktop build is missing: #{refuted.inspect}")
  end
end
