# frozen_string_literal: true

require "test_helper"

require "stringio"
require "tmpdir"
require "pathname"

# Where a build prints — the `out:` and `err:` it is handed.
#
# A build prints two kinds of thing: the warnings the guardrails found, and the
# disassembly `dump_func` asked for. Both go wherever the caller pointed them, and a
# caller points them at one of three things — an open stream, the name of a file, or
# nothing at all because it wants the build quiet.
#
# The name of a file is the case worth a test file of its own, because `File::NULL` is a
# name: it is the string "/dev/null". So "build quietly" gets written as a path far more
# often than as anything else, and a path that worked only until the build had a warning to
# give would fail at the worst possible moment — the build that finally has something to
# say would be the build that cannot say it.
class TestBuildOutput < Minitest::Test

  # A game that gives the guardrails something to report. Writing the wait for the
  # screen by hand is harmless and the build says so, which is all this needs: a
  # warning, on a build that otherwise does nothing.
  def game_that_warns
    RubyGBA.game "OUTPUT" do
      screen :bitmap
      var :n, 0
      game_loop do
        wait_vblank
        add! :n, 1
      end
    end
  end

  def build(game, out: nil, err: nil)
    game.build_rom(out: out, err: err, profile: false)
  end

  # The reported bug: eight call sites wrote this, all eight built correctly for
  # months, and all eight broke in the same hour — the hour somebody added a
  # construct that warns.
  def test_a_build_that_warns_can_be_pointed_at_the_null_device_by_name
    rom = build(game_that_warns, out: File::NULL, err: File::NULL)

    assert_kind_of RubyGBA::ROM, rom
  end

  # And a path is not merely tolerated: what the build had to say is in the file
  # afterwards, and the file is closed, so the caller has nothing to look after.
  def test_a_path_is_opened_written_to_and_closed_again
    Dir.mktmpdir do |dir|
      path = File.join(dir, "build.log")

      build(game_that_warns, err: path)

      assert_match(/frame_sync/, File.read(path), "the warning belongs in the file the caller named")
    end
  end

  # Nothing at all means build quietly, which is what every caller who reached for
  # File::NULL actually meant. Nothing reaches the process's own streams.
  def test_nothing_at_all_means_build_quietly
    printed, complained = capture_io { build(game_that_warns) }

    assert_empty printed
    assert_empty complained
  end

  # A stream still works, which is how the suite captures what a build said.
  def test_an_open_stream_is_written_to_as_it_always_was
    err = StringIO.new

    build(game_that_warns, err: err)

    assert_match(/frame_sync/, err.string)
  end

  # And a stream the caller opened is still open afterwards. It belongs to the caller,
  # who may be building twice into the same log — closing it here would leave the second
  # build writing to a closed file.
  def test_a_stream_the_caller_opened_is_left_open
    Dir.mktmpdir do |dir|
      File.open(File.join(dir, "build.log"), "w") do |file|
        build(game_that_warns, err: file)

        refute_predicate file, :closed?
        file.puts("and the caller can go on writing")
      end
    end
  end

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

  # A Pathname is a name too, and it says so about itself rather than being one.
  def test_a_pathname_is_a_name_like_any_other
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir) + "build.log"

      build(game_that_warns, err: path)

      assert_match(/frame_sync/, path.read)
    end
  end

  # A path is opened at the START of the build, so a name that cannot be opened at all
  # stops the build before it reads the game rather than after it has built a cartridge.
  # The flag stays false because the game's own block never ran.
  def test_a_name_that_cannot_be_opened_stops_the_build_before_it_reads_the_game
    read = false
    game = RubyGBA.game "OUTPUT" do
      read = true
      screen :bitmap
      game_loop { halt }
    end

    assert_raises(Errno::ENOENT) { build(game, err: "/no/such/place/build.log") }
    refute read, "the build must stop before it reads the game"
  end
end
