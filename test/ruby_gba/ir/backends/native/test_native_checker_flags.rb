# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require "open3"
require "tmpdir"

# The flags an editor's C checker is handed for the native runtime (Zig.checker_flags, kept in a
# compile_flags.txt above it by every build) are enough to read every one of its files the way
# the build does: the build's own warnings, and the folders its headers are found in.
class TestNativeCheckerFlags < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  Zig = RubyGBA::IR::Backends::Native::Zig

  # The window's file reads SDL's headers, which are on the machine only once a desktop build
  # has fetched SDL; every other file needs nothing but the runtime's own folder.
  WINDOW_FILE = "rg_sdl.c"

  private def runtime_files = Dir.glob(File.join(Zig::RUNTIME_DIR, "*.c")).sort

  # What the compiler says about one file read with those flags and nothing else, or nil when it
  # has nothing to say. The file is compiled on its own into something thrown away, which is the
  # nearest zig comes to only checking it.
  private def complaints_about(file)
    Dir.mktmpdir do |dir|
      _out, err, status = Open3.capture3("zig", "cc", "-c", *Zig.checker_flags, "-o", File.join(dir, "checked.o"), file)
      status.success? ? nil : "#{File.basename(file)}:\n#{err}"
    end
  end

  def test_every_file_of_the_runtime_passes_a_check_under_them
    checked = runtime_files.reject { |file| File.basename(file) == WINDOW_FILE }

    refute_empty checked
    assert_empty checked.filter_map { |file| complaints_about(file) }
  end

  # The C the tests compile beside the runtime (a harness that drives one header on its own) is
  # read by the checker with the flags kept beside it, which a build keeps as fresh as the others.
  def test_building_a_game_as_c_keeps_the_test_harnesses_flags_too
    File.write(Zig::HARNESS_CHECKER_FLAGS_FILE, "-Wnothing\n")

    Native.new.build_headless(program_of { game_loop {} })
    written = File.readlines(Zig::HARNESS_CHECKER_FLAGS_FILE, chomp: true)

    assert_empty [*Zig::WARNINGS, "-I#{Zig::RUNTIME_DIR}"] - written
    refute_includes written, "-Wnothing"
    harnesses = Dir.glob(File.join(File.dirname(Zig::HARNESS_CHECKER_FLAGS_FILE), "*.c"))
    refute_empty harnesses
    assert_empty harnesses.filter_map { |file| complaints_about(file) }
  ensure
    Zig.refresh_checker_flags(Zig::HARNESS_CHECKER_FLAGS_FILE)
  end

  def test_the_windows_file_passes_once_sdl_has_been_fetched
    skip "SDL has not been fetched on this machine: build a game for the desktop once" if Zig.sdl_include_dir.nil?

    assert_nil complaints_about(File.join(Zig::RUNTIME_DIR, WINDOW_FILE))
  end

  def test_they_are_written_one_to_a_line_for_the_checker_to_read
    Dir.mktmpdir do |dir|
      path = File.join(dir, "compile_flags.txt")

      assert Zig.refresh_checker_flags(path), "a file that is not there should be written"
      assert_equal Zig.checker_flags, File.readlines(path, chomp: true)
    end
  end

  def test_a_file_that_is_already_right_is_left_alone_and_a_wrong_one_is_put_right
    Dir.mktmpdir do |dir|
      path = File.join(dir, "compile_flags.txt")
      Zig.refresh_checker_flags(path)

      refute Zig.refresh_checker_flags(path), "nothing changed, so nothing should be written"

      File.write(path, "-Wnothing\n")
      assert Zig.refresh_checker_flags(path), "a file that has gone out of date should be written again"
      assert_equal Zig.checker_flags, File.readlines(path, chomp: true)
    end
  end

  # Nobody runs anything to get the file: building a game as C is what keeps it right, whether
  # or not that game has been built before.
  def test_building_a_game_as_c_puts_a_stale_file_right
    program = program_of do
      x = var :x, 0
      game_loop { x.add! 1 }
    end
    File.write(Zig::CHECKER_FLAGS_FILE, "-Wnothing\n")

    2.times do
      Native.new.build_headless(program)
      written = File.readlines(Zig::CHECKER_FLAGS_FILE, chomp: true)

      # The build's warnings and the runtime's folder, which never change during a run. SDL's
      # folder is left out of this one: the window's test may be fetching SDL at this moment.
      assert_empty [*Zig::WARNINGS, "-I#{Zig::RUNTIME_DIR}"] - written
      refute_includes written, "-Wnothing"
    end
  ensure
    Zig.refresh_checker_flags # whatever happened above, the real file is not left wrong
  end

  # The desktop build's own list of warnings is a copy kept in build/build.zig. It has to be the
  # list a test's compile and the checker are handed, or the three hold the code to different things.
  def test_the_desktop_build_holds_the_code_to_the_same_warnings
    build_file = File.read(Zig::BUILD_FILE)

    assert_empty(Zig::WARNINGS.reject { |flag| build_file.include?(%("#{flag}")) })
  end

  def test_they_hold_the_code_to_what_the_build_does
    assert_empty Zig::WARNINGS - Zig.checker_flags
    assert_includes Zig.checker_flags, "-I#{Zig::RUNTIME_DIR}"
  end
end
