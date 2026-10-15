# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require RubyGBA.root.join("tools/suite_lock").to_s

# A WHOLE RUN OF EITHER SUITE HAS THE MACHINE TO ITSELF. `rake test` and `rake test:native` are
# each sized to use the machine, so the second to start waits for the first, and says so.
class TestSuiteLock < Minitest::Test
  runs_on :reference

  def test_a_second_run_waits_for_the_first_and_says_what_it_waits_for
    Dir.mktmpdir do |folder|
      path = File.join(folder, "suites.lock")
      first = SuiteLock.hold("rake test", path: path, io: StringIO.new)
      said = StringIO.new
      second = Thread.new { SuiteLock.hold("rake test:native", path: path, io: said) }
      begin
        Thread.pass until said.string.include?("\n") || !second.alive?
        assert_predicate second, :alive?, "the second run went ahead while the first held the lock"
        assert_match(/rake test \(process #{Process.pid}\)/, said.string)
      ensure
        first.close # lets the second through, whatever was asserted
        second.value.close
      end
    end
  end

  def test_a_run_with_nobody_ahead_of_it_says_nothing
    Dir.mktmpdir do |folder|
      said = StringIO.new
      SuiteLock.hold("rake test", path: File.join(folder, "suites.lock"), io: said).close

      assert_empty said.string
    end
  end
end
