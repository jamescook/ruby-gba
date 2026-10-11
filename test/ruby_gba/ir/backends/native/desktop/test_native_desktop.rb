# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require "tmpdir"
require_relative "../../../../../../examples/pong"

# The program a player runs — pong with its window, built with SDL — is the same program the
# tests drive: started with --headless it plays a recorded run with no window, and shows the
# interpreter's picture pixel for pixel. Started normally, it opens its window and keeps going
# until it is closed.
#
# Only under `rake test:native SDL=1`: the first desktop build fetches SDL's source over the
# network and compiles it, which no ordinary run of the suite should have to wait for.
class TestNativeDesktop < Minitest::Test
  # Starts child processes (zig, and the program it builds), which Ruby cannot do from inside a
  # Ractor — the spawn waits for ever — so on the main Ractor, not in the pool. See test_helper.
  runs_on_the_main_ractor!

  include NativeComparison

  RUN = Ractor.make_shareable({ 10 => %i[down], 14 => %i[up], 20 => %i[a] })

  def test_the_desktop_program_run_headless_matches_the_interpreter
    Dir.mktmpdir do |dir|
      exe = Native.new.build_desktop(PongGame::GAME, File.join(dir, "pong"), err: nil)
      program = Native.new.checked_program(PongGame::GAME, err: nil)
      input = (1..40).map { |frame| "#{button_mask(RUN.fetch(frame, []))}\n" }.join

      actual = parse_snapshots(Native::Zig.run_program(exe, args: ["--headless", 40], input: input))
      expected = reference_snapshots(program, frames: 40, buttons: RUN)

      assert_equal expected.map(&:heading), actual.map(&:heading)
      expected.zip(actual).each { |want, got| assert_same_moment(want, got, :desktop) }
    end
  end

  # With SDL's own stand-in drivers it needs no screen, so this runs anywhere: the window opens,
  # frames go by, and nothing stops it but being told to.
  def test_the_desktop_program_opens_its_window_and_keeps_running
    Dir.mktmpdir do |dir|
      exe = Native.new.build_desktop(PongGame::GAME, File.join(dir, "pong"), err: nil)
      pid = Process.spawn({ "SDL_VIDEO_DRIVER" => "dummy" }, exe, err: File::NULL)
      sleep 2

      assert_nil Process.wait(pid, Process::WNOHANG), "the game stopped on its own"
    ensure
      Process.kill(:KILL, pid) if pid
      Process.wait(pid) if pid
    end
  end
end
