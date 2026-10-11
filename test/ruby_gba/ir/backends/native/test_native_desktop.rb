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
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  RUN = Ractor.make_shareable({ 10 => %i[down], 14 => %i[up], 20 => %i[a] })
  FRAMES = 40

  # The title's menus worked the way a person works them, each button held for several frames:
  # down to the music row and A to turn it off, down to DIFFICULTY and A to open it, up to NORMAL
  # and A to choose it.
  MENU_RUN = Ractor.make_shareable(
    NativeComparison.held_for([10..15, :down], [30..38, :a], [50..55, :down], [70..78, :a], [95..100, :up], [115..122, :a])
  )
  MENU_FRAMES = 140

  # SDL's stand-ins for a display and for sound, so the window needs no screen and a test does
  # not play pong out of the speakers of whoever runs it.
  NO_SCREEN_OR_SPEAKER = { "SDL_VIDEO_DRIVER" => "dummy", "SDL_AUDIO_DRIVER" => "dummy" }.freeze

  def test_the_program_a_player_runs
    Dir.mktmpdir do |dir|
      exe = Native.new.build_desktop(PongGame::GAME, File.join(dir, "pong"), err: nil)

      assert_runs_headless_like_the_interpreter(exe)
      assert_keys_work_the_menus_through_the_window(exe)
      assert_keeps_running_with_its_window(exe)
      assert_needs_nothing_installed(exe) if RUBY_PLATFORM.include?("darwin")
    end
  end

  private

  # Started with --headless it plays a recorded run with no window, and shows the interpreter's
  # picture pixel for pixel.
  def assert_runs_headless_like_the_interpreter(exe)
    input = (1..FRAMES).map { |frame| "#{Native::HeadlessRun.button_mask(RUN.fetch(frame, []))}\n" }.join
    program = Native.new.checked_program(PongGame::GAME, err: nil)
    actual = parse_snapshots(Native::Zig.run_program(exe, args: ["--headless", FRAMES, "--every-picture"], input: input), program)
    expected = reference_snapshots(program, frames: FRAMES, buttons: RUN)

    assert_equal expected.map(&:heading), actual.map(&:heading)
    expected.zip(actual).each { |want, got| assert_same_moment(want, got, :desktop) }
  end

  # Started with its window (on SDL's stand-in display) and keys pressed from a script: each
  # press is a key event through SDL, onto the gamepad the keyboard is, and round the window's own
  # frame loop — the way in that --headless goes round. A key held for several frames must still
  # count once, so the music ends up off, the difficulty screen is opened and left, and the cpu
  # paddle is at NORMAL's speed — where the interpreter ends given the same buttons.
  def assert_keys_work_the_menus_through_the_window(exe)
    input = (1..MENU_FRAMES).map { |frame| "#{Native::HeadlessRun.button_mask(MENU_RUN.fetch(frame, []))}\n" }.join
    printed = Native::Zig.run_program(exe, args: ["--scripted-keys", MENU_FRAMES], input: input, env: NO_SCREEN_OR_SPEAKER)
    program = Native.new.checked_program(PongGame::GAME, err: nil)
    expected = reference_snapshots(program, frames: MENU_FRAMES, buttons: MENU_RUN).last.variables

    assert_equal [0, 0], expected.values_at(:music_on, :state), "the run should turn the music off and come back to the title"
    assert_empty variable_differences(expected, Native::HeadlessRun.variables_in(printed.lines.map(&:chomp)))
  end

  # Started normally, with SDL's stand-in display so it needs no screen, it opens its window and
  # is still running a couple of seconds later: nothing stops it but being told to.
  def assert_keeps_running_with_its_window(exe)
    pid = Process.spawn(NO_SCREEN_OR_SPEAKER, exe, err: File::NULL)
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
