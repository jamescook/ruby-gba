# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require "fileutils"
require "open3"
require "tmpdir"
require RubyGBA.root.join("examples/pong").to_s

# The program a player runs — pong with its window, built with SDL — is the same program the
# tests drive, and it stands on its own.
#
# Only under `rake test:native SDL=1`: the first desktop build fetches SDL's source over the
# network and compiles it, which no ordinary run of the suite should have to wait for. One test
# of pong, because each desktop build is a whole game built with SDL — and one of a game of a few
# lines that saves, since pong keeps nothing and the window's save file is the window's own code.
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
      assert_says_how_evenly_its_pictures_were_shown(exe)
      assert_keeps_running_with_its_window(exe)
      assert_needs_nothing_installed(exe) if RUBY_PLATFORM.include?("darwin")
    end
  end

  # A press of A on two frames of a short run, for the game below.
  KEPT_RUN = Ractor.make_shareable({ 3 => %i[a], 7 => %i[a] })
  KEPT_FRAMES = 12

  # A game that keeps one number in save memory: 5 on a new cartridge, and two more at each
  # press of A. Made where it is used, since a game is not something a test may keep in a
  # constant.
  private def game_that_keeps_a_count
    RubyGBA.game("KEEPER") do
      screen :bitmap
      best = save_var :best, 5
      game_loop do
        clear_screen :black
        pressed(:a).then { best.add! 2 }
      end
    end
  end

  # THE WINDOW KEEPS THE GAME'S SAVE IN A FILE, holding the bytes the interpreter's save memory
  # holds after the same presses — a .sav file, as an emulator keeps one.
  def test_the_program_a_player_runs_keeps_its_save_in_a_file
    game = game_that_keeps_a_count
    saved = SaveImage.new
    Reference.new(save: saved).input_each_frame { |frame| KEPT_RUN.fetch(frame, []) }
             .run(Native.new.checked_program(game, err: nil), frames: KEPT_FRAMES)
    assert_equal 9, saved.word(RubyGBA::IR::SaveLayout.save_var_at(0)), "two presses should take the count from 5 to 9"

    Dir.mktmpdir do |dir|
      exe = Native.new.build_desktop(game, File.join(dir, "keeper"), err: nil)

      assert_keeps_its_save_in_the_file_it_is_told(exe, File.join(dir, "told.sav"), saved)
      assert_writes_its_save_while_it_is_still_running(exe, File.join(dir, "running.sav"))
      assert_keeps_its_save_among_the_files_of_whoever_plays(exe, File.join(dir, "home"), saved)
      assert_refuses_a_file_that_is_not_its_save(exe, File.join(dir, "other.sav"))
    end
  end

  # THE SAME GAME FOR ANOTHER COMPUTER, built from this one: zig carries the C library of each, and
  # SDL is compiled for each from its own source. These are only built here, not run — nothing
  # here can run them — so what is checked is that each is a program for the computer it was asked
  # for, read off the first bytes of the file the way that computer reads them.
  WINDOWS_PROGRAM = "MZ".b
  LINUX_PROGRAM = "\x7FELF".b
  ELF_MACHINE = { linux: 0x3E, linux_arm: 0xB7 }.freeze # x86-64 and 64-bit ARM, at byte 18

  def test_a_program_for_windows_and_for_linux_is_built_from_here
    Dir.mktmpdir do |dir|
      windows = Native.new.build_desktop(PongGame::GAME, File.join(dir, "pong.exe"), target: :windows, err: nil)
      assert_equal WINDOWS_PROGRAM, File.binread(windows, 2)

      ELF_MACHINE.each do |target, machine|
        linux = Native.new.build_desktop(PongGame::GAME, File.join(dir, "pong-#{target}"), target: target, err: nil)
        head = File.binread(linux, 20)
        assert_equal LINUX_PROGRAM, head[0, 4], "#{target} is a Linux program"
        assert_equal machine, head.byteslice(18, 2).unpack1("v"), "#{target} is for the processor asked for"
      end
    end
  end

  private

  # What a run of the game with its window (on SDL's stand-in display) printed at its end, with
  # keys pressed from +presses+.
  def variables_after(exe, frames, presses, *options, env: {})
    input = (1..frames).map { |frame| "#{Native::HeadlessRun.button_mask(presses.fetch(frame, []))}\n" }.join
    printed = Native::Zig.run_program(exe, args: ["--scripted-keys", frames, *options], input: input,
                                           env: NO_SCREEN_OR_SPEAKER.merge(env))
    Native::HeadlessRun.variables_in(printed.lines.map(&:chomp))
  end

  # Told a file (--save-file), it leaves the save there, with nothing beside it: the new file it
  # writes first has taken the save file's place. Started again, it reads the file before the
  # game starts, so the count carries on from where it was.
  def assert_keeps_its_save_in_the_file_it_is_told(exe, path, saved)
    assert_equal 9, variables_after(exe, KEPT_FRAMES, KEPT_RUN, "--save-file", path)[:best]

    assert_equal saved.to_sav, File.binread(path)
    refute_path_exists "#{path}.writing"
    assert_equal 11, variables_after(exe, 5, { 3 => %i[a] }, "--save-file", path)[:best]
  end

  # The file is written soon after the game saves, and not only as the window closes: A is
  # pressed on the third frame of a run with hours left in it, the file holds the count that
  # press made within a few seconds, and only then is the program stopped — the way a crash
  # stops one, with no chance to write anything. (The file is there before the press, holding
  # the 5 a new cartridge is given as the game starts, so it is the count that is waited for.)
  def assert_writes_its_save_while_it_is_still_running(exe, path)
    keys = "#{path}.keys"
    File.write(keys, "0\n0\n#{Native::HeadlessRun.button_mask(%i[a])}\n")
    pid = Process.spawn(NO_SCREEN_OR_SPEAKER, exe, "--scripted-keys", "1000000", "--save-file", path,
                        in: keys, out: File::NULL, err: File::NULL)
    count = -> { File.exist?(path) && SaveImage.read_sav(path).word(RubyGBA::IR::SaveLayout.save_var_at(0)) }
    give_up = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    sleep 0.05 until count.call == 7 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > give_up

    assert_equal 7, count.call, "the save file should hold the count while the game is still running"
    assert_nil Process.wait(pid, Process::WNOHANG), "and the game should still be running"
  ensure
    if pid
      Process.kill(:KILL, pid)
      Process.wait(pid)
    end
  end

  # Told nothing, it keeps the save where the operating system keeps a program's own files for
  # the person using the computer, in a folder named for the game. The test says where that
  # person's files are, in the two ways a Mac and a Linux machine are told, so nothing is
  # written among the files of whoever runs it; on a system told neither way it is not tried.
  def assert_keeps_its_save_among_the_files_of_whoever_plays(exe, home, saved)
    return unless RUBY_PLATFORM.match?(/darwin|linux/)

    FileUtils.mkdir_p(home)
    variables_after(exe, KEPT_FRAMES, KEPT_RUN, env: { "CFFIXED_USER_HOME" => home, "XDG_DATA_HOME" => home })
    found = Dir.glob(File.join(home, "**", "save.sav"))

    assert_equal 1, found.length, "one save file should be under #{home}: #{Dir.glob(File.join(home, '**', '*')).inspect}"
    assert found.first.end_with?(File.join("ruby-gba", "KEEPER", "save.sav")), "the folder should be the game's: #{found.first}"
    assert_equal saved.to_sav, File.binread(found.first)
  end

  # A file there that is not as big as the game's save memory is another game's, or damaged: the
  # game does not start, says why, and leaves the file as it is.
  def assert_refuses_a_file_that_is_not_its_save(exe, path)
    File.binwrite(path, "x" * 100)
    _printed, said, status = Open3.capture3(NO_SCREEN_OR_SPEAKER, exe, "--scripted-keys", "2", "--save-file", path,
                                            stdin_data: "0\n0\n")

    refute_predicate status, :success?
    assert_match(/is not a save of this game, whose save is 32768 bytes/, said)
    assert_equal "x" * 100, File.binread(path)
  end

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

  # Asked for its frame times, it says on the error stream what paced the frames and how far
  # apart the pictures were handed over, which is the only way to see a stutter without looking
  # at a screen. The stand-in display says nothing of its rate, so it is told to pace as for a
  # monitor that refreshes sixty times a second: the monitor then paces the game, a picture every
  # sixtieth of a second, and a second's worth of frames takes about a second.
  def assert_says_how_evenly_its_pictures_were_shown(exe)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _printed, said, status = Open3.capture3(NO_SCREEN_OR_SPEAKER, exe, "--scripted-keys", "60", "--frame-times",
                                            "--refresh-rate", "60", stdin_data: "0\n" * 60)
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_predicate status, :success?, said
    assert_match(/^pacing: the monitor, 1 refreshes a picture/, said)
    assert_match(/^uneven \(more than 2 ms from the middle\): \d+/, said)
    middle = said[/^pictures: 60, [\d.]+ to [\d.]+ ms apart, ([\d.]+) in the middle$/, 1]
    assert_in_delta 1000.0 / 60, middle.to_f, 1.5, "the pictures should be a sixtieth of a second apart: #{said}"
    assert_operator took, :>, 0.8, "sixty frames should take about a second"
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
