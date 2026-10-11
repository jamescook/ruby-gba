# frozen_string_literal: true

require "test_helper"

# Names only the native lowering, so it fails if anything but `rake test:native` runs it. Every
# test in this folder names only native too, and `rake test` loads them all: this is the one that
# says so the day the filter stops working. Its other side is test/test_suites.rb.
class TestNativeSuite < Minitest::Test
  runs_on :native

  def test_a_class_that_names_only_native_runs_only_on_a_native_run
    assert_equal :native, TestSuites::LOWERING,
                 "a test class that said `runs_on :native` alone ran on a #{TestSuites::LOWERING} run"
  end

  # A file opted into native runs keeps its tests of the cartridge, which skip themselves here.
  def test_a_test_of_the_cartridge_skips_itself_on_a_native_run_and_says_why
    skipped = assert_raises(Minitest::Skip) { require_emulator! }

    assert_match(/emulator/, skipped.message)
  end

  # ...and a test that asks something native cannot answer yet says so, with its reason.
  def test_a_test_native_cannot_play_yet_skips_with_its_reason
    skipped = assert_raises(Minitest::Skip) { skip_on_native "reads the sprites by name" }

    assert_match(/reads the sprites by name/, skipped.message)
  end
end
