# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "rbconfig"

# End-to-end tests for the `ruby-gba` command. These are the only tests that touch
# Thor: they run bin/ruby-gba in a subprocess, the way a user does, so the CLI (and
# its dependency) stays out of every other test. Everything else builds ROMs through
# the library (RubyGBA.game / RubyGBA.build) with no CLI involved.
class TestCLI < Minitest::Test
  BIN = File.expand_path("../bin/ruby-gba", __dir__)

  # Run the CLI in +dir+ and return [combined_output, Process::Status].
  def cli(*args, dir:)
    Open3.capture2e(RbConfig.ruby, BIN, *args, chdir: dir)
  end

  def test_new_scaffolds_a_game_that_builds_and_runs
    Dir.mktmpdir do |dir|
      out, status = cli("new", "demo", dir: dir)
      assert status.success?, out
      assert File.exist?(File.join(dir, "demo.rb")), "new should write demo.rb"

      build_out, build_status = cli("build", "demo.rb", dir: dir)
      assert build_status.success?, build_out
      assert File.exist?(File.join(dir, "demo.gba")), "build should write demo.gba"
      assert_match(/Built demo\.gba \(\d+ bytes\)/, build_out)
    end
  end

  def test_build_honors_the_output_path
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = cli("build", "demo.rb", "-o", "roms/custom.gba", dir: dir)
      # -o points at a subdir the CLI does not create, so this proves -o is read; a
      # bare build (no -o) writes beside the source, covered above.
      if status.success?
        assert File.exist?(File.join(dir, "roms/custom.gba"))
      else
        assert_match(/custom\.gba/, out)
      end
    end
  end

  def test_a_missing_game_file_is_a_friendly_error_not_a_backtrace
    Dir.mktmpdir do |dir|
      out, status = cli("build", "nope.rb", dir: dir)
      refute status.success?, "a missing file should fail"
      assert_match(/cannot find the game file/, out)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  def test_inspect_reports_the_header_of_a_built_rom
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      cli("build", "demo.rb", dir: dir)
      out, status = cli("inspect", "demo.gba", dir: dir)
      assert status.success?, out
      assert_match(/GBA ROM Header/, out)
      assert_match(/Checksum:.*OK/, out)
    end
  end

  def test_analyze_reports_a_measured_per_frame_cost
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = cli("build", "demo.rb", "--analyze", dir: dir)
      assert status.success?, out
      assert_match(/measured on emulator: .*scanlines per frame/, out)
    end
  end

  def test_stats_reports_asset_packing_for_a_tiled_game
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "packy.rb"), <<~RUBY)
        require "ruby_gba"
        Packy = RubyGBA.game "PACKY", code: "BPKY", maker: "01" do
          screen :tiled
          image(:red_t, "#" => :red) { (["########"] * 8).join("\\n") }
          tiles :set, "R" => :red_t
          background :bg, tiles: :set, map: Array.new(32) { "R" * 32 }
          game_loop { wait_vblank; halt }
        end
      RUBY
      out, status = cli("build", "packy.rb", "--stats", dir: dir)
      assert status.success?, out
      assert_match(/Packed \d+ assets? with (LZ77|RLE)/, out)
    end
  end
end
