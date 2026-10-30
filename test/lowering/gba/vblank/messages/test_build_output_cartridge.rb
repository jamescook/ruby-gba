# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "all/vblank/messages/test_build_output"

# Where a measured build prints: it runs the Advance's cartridge in the emulator between its two
# builds. Where every other build prints is in test/all/vblank/messages/test_build_output.rb.
class TestBuildOutputCartridge < Minitest::Test
  include BuildOutputGames

  # A measured build builds the game twice (it runs the first cartridge to find out where
  # the frames go, then builds again knowing). Both builds write to the one file the caller
  # named: it is opened once, before either of them, and closed once, after both. Opening it
  # per build would leave the second truncating what the first had to say.
  def test_a_measured_build_writes_both_of_its_builds_to_one_file
    require_emulator!

    Dir.mktmpdir do |dir|
      path = File.join(dir, "build.log")

      game_that_warns.build_rom(out: nil, err: path, profile: true)

      assert_match(/frame_sync/, File.read(path))
    end
  end
end
