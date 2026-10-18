# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# A checkout's build has to come from the C source beside it.
#
# The Ruby half of this gem is read fresh from the checkout every time, and the compiled half is
# whatever was last built there. Pull new code without rebuilding and the two disagree: the Ruby
# asks the extension for something it does not hand back yet, and the first anybody hears of it
# is a NoMethodError several calls into the profiler. So the build records the source it came
# from, and loading a build that came from other source stops with what to do about it.
class TestRubyGBAEmulatorBuiltFrom < Minitest::Test
  def test_the_build_carries_the_fingerprint_of_the_source_beside_it
    assert_equal RubyGBAEmulator.source_fingerprint, RubyGBAEmulator::BUILT_FROM
  end

  def test_a_build_from_other_source_is_refused_with_how_to_rebuild
    error = assert_raises(RubyGBAEmulator::OutOfDate) do
      RubyGBAEmulator.refuse_out_of_date_build!(built_from: "0" * 64)
    end

    assert_includes error.message, "rake compile"
    assert_includes error.message, File.expand_path("..", __dir__)
  end

  # A build from before builds carried a fingerprint is out of date by definition.
  def test_a_build_with_no_fingerprint_is_refused
    assert_raises(RubyGBAEmulator::OutOfDate) do
      RubyGBAEmulator.refuse_out_of_date_build!(built_from: nil)
    end
  end

  # What a build leaves in the source directory (the Makefile, the object files) is not source.
  def test_the_fingerprint_follows_the_c_source_and_nothing_else
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "ext.c"), "int a;")
      before = RubyGBAEmulator.source_fingerprint(dir)
      File.write(File.join(dir, "Makefile"), "all:")
      assert_equal before, RubyGBAEmulator.source_fingerprint(dir)

      File.write(File.join(dir, "ext.h"), "int b;")
      refute_equal before, RubyGBAEmulator.source_fingerprint(dir)
    end
  end
end
