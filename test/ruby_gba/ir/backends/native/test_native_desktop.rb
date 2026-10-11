# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require "tmpdir"
require_relative "../../../../../examples/pong"

# The program a player runs — pong with its window, built with SDL — is the same program the
# tests drive, and it stands on its own.
#
# Only under `rake test:native SDL=1`: the first desktop build fetches SDL's source over the
# network and compiles it, which no ordinary run of the suite should have to wait for. One test,
# because each desktop build is a whole game built with SDL.
class TestNativeDesktop < Minitest::Test
  # Starts child processes (zig, and the program it builds), which Ruby cannot do from inside a
  # Ractor — the spawn waits for ever — so on the main Ractor, not in the pool. See test_helper.
  runs_on_the_main_ractor!

  include NativeComparison

  RUN = Ractor.make_shareable({ 10 => %i[down], 14 => %i[up], 20 => %i[a] })
  FRAMES = 40

  def test_the_program_a_player_runs
    Dir.mktmpdir do |dir|
      exe = Native.new.build_desktop(PongGame::GAME, File.join(dir, "pong"), err: nil)

      assert_runs_headless_like_the_interpreter(exe)
      assert_keeps_running_with_its_window(exe)
      assert_needs_nothing_installed(exe) if RUBY_PLATFORM.include?("darwin")
    end
  end

  private

  # Started with --headless it plays a recorded run with no window, and shows the interpreter's
  # picture pixel for pixel.
  def assert_runs_headless_like_the_interpreter(exe)
    input = (1..FRAMES).map { |frame| "#{button_mask(RUN.fetch(frame, []))}\n" }.join
    actual = parse_snapshots(Native::Zig.run_program(exe, args: ["--headless", FRAMES], input: input))
    expected = reference_snapshots(Native.new.checked_program(PongGame::GAME, err: nil), frames: FRAMES, buttons: RUN)

    assert_equal expected.map(&:heading), actual.map(&:heading)
    expected.zip(actual).each { |want, got| assert_same_moment(want, got, :desktop) }
  end

  # Started normally, with SDL's stand-in display so it needs no screen, it opens its window and
  # is still running a couple of seconds later: nothing stops it but being told to.
  def assert_keeps_running_with_its_window(exe)
    pid = Process.spawn({ "SDL_VIDEO_DRIVER" => "dummy" }, exe, err: File::NULL)
    sleep 2
    stopped = Process.wait(pid, Process::WNOHANG)

    assert_nil stopped, "the game stopped on its own"
  ensure
    if pid && stopped.nil?
      Process.kill(:KILL, pid)
      Process.wait(pid)
    end
  end

  # The only libraries it reaches for are the operating system's own: SDL is inside it.
  def assert_needs_nothing_installed(exe)
    libraries = `otool -L #{exe}`.lines.drop(1).map { |line| line.strip.split(" ").first }

    assert_empty libraries.reject { |lib| lib.start_with?("/System/Library/", "/usr/lib/") }
  end
end
