# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require VBlank.root.join("tools/suite_lock").to_s

# A WHOLE RUN HAS THE MACHINE TO ITSELF. `rake test` and each lowering's run on its own are
# sized to use the machine, so the second to start waits for the first, and says so.
class TestSuiteLock < Minitest::Test
  def test_a_second_run_waits_for_the_first_and_says_what_it_waits_for
    Dir.mktmpdir do |folder|
      path = File.join(folder, "suites.lock")
      first = SuiteLock.hold("rake test", path: path, io: StringIO.new)
      said = StringIO.new
      second = Thread.new { SuiteLock.hold("rake test:lowering:native", path: path, io: said) }
      begin
        Thread.pass until said.string.include?("\n") || !second.alive?
        assert_predicate second, :alive?, "the second run went ahead while the first held the lock"
        assert_match(/rake test in #{Regexp.escape(Dir.pwd)} \(process #{Process.pid}\)/, said.string)
        assert_match(/VBLANK_SUITE_LOCK=checkout/, said.string, "and says how to stop waiting")
      ensure
        first.close # lets the second through, whatever was asserted
        second.value.close
      end
    end
  end

  # One lock for the machine unless a checkout asks for its own, which is its own whatever folder
  # it is in and the same each time it asks.
  def test_the_lock_is_the_machines_unless_a_checkout_asks_for_its_own
    assert_equal SuiteLock::PATH, SuiteLock.chosen_path(nil, checkout: "/work/ruby-gba")
    assert_equal SuiteLock::PATH, SuiteLock.chosen_path("machine", checkout: "/work/ruby-gba")

    own = SuiteLock.chosen_path("checkout", checkout: "/work/ruby-gba")
    other = SuiteLock.chosen_path("checkout", checkout: "/work/ruby-gba--gbc-lowering")
    refute_equal SuiteLock::PATH, own
    refute_equal own, other
    assert_equal own, SuiteLock.chosen_path("checkout", checkout: "/work/ruby-gba")
    assert_equal File.dirname(SuiteLock::PATH), File.dirname(own), "kept beside the machine's, not in the checkout"
  end

  def test_a_lock_setting_that_is_neither_is_refused_in_plain_words
    error = assert_raises(ArgumentError) { SuiteLock.chosen_path("mine", checkout: "/work/ruby-gba") }

    assert_match(/VBLANK_SUITE_LOCK is "machine" or "checkout"/, error.message)
  end

  def test_a_run_with_nobody_ahead_of_it_says_nothing
    Dir.mktmpdir do |folder|
      said = StringIO.new
      SuiteLock.hold("rake test", path: File.join(folder, "suites.lock"), io: said).close

      assert_empty said.string
    end
  end
end
