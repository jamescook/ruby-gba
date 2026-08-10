# frozen_string_literal: true

require "test_helper"

require "open3"
require "tmpdir"
require "rbconfig"

# End-to-end tests for the `ruby-gba` command. These are the only tests that touch
# Thor: they run bin/ruby-gba in a subprocess, the way a user does, so the CLI (and
# its dependency) stays out of every other test. Everything else builds ROMs through
# the library (RubyGBA.game / RubyGBA.build) with no CLI involved.
class TestCLI < Minitest::Test
  BIN = File.expand_path("../bin/ruby-gba", __dir__)
  LIB = File.expand_path("../lib", __dir__)

  # Run the CLI in +dir+ and return [combined_output, Process::Status].
  def cli(*args, dir:)
    Open3.capture2e(RbConfig.ruby, BIN, *args, chdir: dir)
  end

  # Run an arbitrary Ruby file (e.g. something `build --format=ir` wrote) as its own
  # process, with the checkout's lib/ on its load path — the way a user who cloned
  # the repo, rather than installed the gem, would run it.
  def run_ruby(path, dir:)
    Open3.capture2e(RbConfig.ruby, "-I", LIB, path, chdir: dir)
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

  def test_explain_folds_in_a_measured_per_frame_cost
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = cli("build", "demo.rb", "--explain", dir: dir)
      assert status.success?, out
      assert_match(/measured ~.*of 228 scanlines/, out)
    end
  end

  # A scened game with SCENE, so `build`'s content is the same across the scene tests.
  SCENED = <<~RUBY
    require "ruby_gba"
    Scened = RubyGBA.game "SCENED", code: "BSCN", maker: "01" do
      screen :bitmap
      var :state, 0
      scene(:title) { clear_screen :blue }
      scene(:play)  { clear_screen :red }
      game_loop do
        wait_vblank
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
  RUBY

  def test_explain_measures_each_scene_by_booting_into_it
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "scened.rb"), SCENED)
      out, status = cli("build", "scened.rb", "--explain", dir: dir)
      assert status.success?, out
      assert_match(/scene :title\s+measured/, out)
      assert_match(/scene :play\s+measured/, out)
    end
  end

  # A game whose expensive state needs a particular combination can say so, instead of
  # relying on the sweep that holds one button at a time. Naming the buttons also asks
  # for the report, so there is no --explain to remember.
  def test_keys_holds_the_named_buttons_and_says_so
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "held.rb"), HELD)
      out, status = cli("build", "held.rb", "--keys", "left", "a", dir: dir)
      assert status.success?, out
      assert_match(/while LEFT\+A are held/, out)
    end
  end

  # A typo in a button name is caught before the emulator runs, and reads as a sentence.
  def test_an_unknown_button_is_a_friendly_error
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "held.rb"), HELD)
      out, status = cli("build", "held.rb", "--keys", "triangle", dir: dir)
      refute status.success?, out
      assert_match(/triangle is not a button/, out)
      assert_match(/start/, out, "the message lists the buttons there are")
    end
  end

  # A game that reads a button, for the --keys tests.
  HELD = <<~RUBY
    require "ruby_gba"
    Held = RubyGBA.game "HELD", code: "BHLD", maker: "01" do
      screen :bitmap
      var :x, 0
      game_loop do
        held(:left).then { add :x, 1 }
      end
    end
  RUBY

  def test_scene_narrows_to_one_and_an_unknown_scene_is_friendly
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "scened.rb"), SCENED)
      out, status = cli("build", "scened.rb", "--scene", "play", dir: dir)
      assert status.success?, out
      assert_match(/scene :play\s+measured/, out)
      refute_match(/scene :title\s+measured/, out)

      bad, bad_status = cli("build", "scened.rb", "--scene", "nope", dir: dir)
      refute bad_status.success?, bad
      assert_match(/no scene named nope/, bad)
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

  # `explain` is `build --explain` without the cartridge: same report, no .gba on disk.
  def test_explain_appears_in_the_command_list
    out, status = cli("help", dir: Dir.tmpdir)
    assert status.success?, out
    assert_match(/ruby-gba explain GAME_FILE/, out)
  end

  def test_explain_prints_the_cost_report_without_building_a_cartridge
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = cli("explain", "demo.rb", dir: dir)
      assert status.success?, out
      assert_match(/per-frame cost/, out)
      refute File.exist?(File.join(dir, "demo.gba")), "explain should not write a .gba"
    end
  end

  def test_explain_a_missing_game_file_is_a_friendly_error_not_a_backtrace
    Dir.mktmpdir do |dir|
      out, status = cli("explain", "nope.rb", dir: dir)
      refute status.success?, "a missing file should fail"
      assert_match(/cannot find the game file/, out)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  def test_explain_subcommand_measures_each_scene_by_booting_into_it
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "scened.rb"), SCENED)
      out, status = cli("explain", "scened.rb", dir: dir)
      assert status.success?, out
      assert_match(/scene :title\s+measured/, out)
      assert_match(/scene :play\s+measured/, out)
    end
  end

  def test_explain_subcommand_scene_narrows_to_one_and_an_unknown_scene_is_friendly
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "scened.rb"), SCENED)
      out, status = cli("explain", "scened.rb", "--scene", "play", dir: dir)
      assert status.success?, out
      assert_match(/scene :play\s+measured/, out)
      refute_match(/scene :title\s+measured/, out)

      bad, bad_status = cli("explain", "scened.rb", "--scene", "nope", dir: dir)
      refute bad_status.success?, bad
      assert_match(/no scene named nope/, bad)
    end
  end

  def test_explain_subcommand_keys_holds_the_named_buttons_and_says_so
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "held.rb"), HELD)
      out, status = cli("explain", "held.rb", "--keys", "left", "a", dir: dir)
      assert status.success?, out
      assert_match(/while LEFT\+A are held/, out)
    end
  end

  # `build --format=ir` emits the game's IR as a standalone Ruby class instead of a
  # cartridge.
  def test_format_ir_prints_a_standalone_class_and_builds_no_cartridge
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = cli("build", "demo.rb", "--format=ir", dir: dir)
      assert status.success?, out
      assert_match(/class DemoIR/, out)
      assert_match(/RubyGBA::IR::Nodes\.build/, out)
      assert_match(/DemoIR\.new\.lower if \$PROGRAM_NAME == __FILE__/, out)
      refute File.exist?(File.join(dir, "demo.gba")), "--format=ir should not build a cartridge"
    end
  end

  def test_format_ir_with_output_writes_a_file_that_runs_on_its_own
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = cli("build", "demo.rb", "--format=ir", "-o", "demo_ir.rb", dir: dir)
      assert status.success?, out
      assert_match(/Wrote demo_ir\.rb/, out)

      written = File.join(dir, "demo_ir.rb")
      assert_match(/class DemoIR/, File.read(written))

      run_out, run_status = run_ruby(written, dir: dir)
      assert run_status.success?, run_out
      refute File.exist?(File.join(dir, "demo.gba")), "running the emitted class should not build a cartridge either"
    end
  end

  def test_format_ir_rejects_an_unknown_format
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = cli("build", "demo.rb", "--format", "bogus", dir: dir)
      refute status.success?, "an unknown format should fail"
      assert_match(/"bogus" is not a build format/, out)
      assert_match(/game, ir/, out)
    end
  end

  # A game split across files the way examples/hero.rb's "scene as a class in its
  # own file" pattern does — the dumped IR has to be one self-contained class
  # regardless of how many source files built the tree it holds.
  def test_format_ir_works_for_a_game_declared_across_multiple_files
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "extra_state.rb"), <<~RUBY)
        module ExtraState
          def self.declare(builder)
            builder.instance_eval { var :score, 0 }
          end
        end
      RUBY
      File.write(File.join(dir, "multi.rb"), <<~RUBY)
        require "ruby_gba"
        require_relative "extra_state"

        Multi = RubyGBA.game "MULTI", code: "BMLT", maker: "01" do
          screen :bitmap
          ExtraState.declare(self)
          game_loop { add :score, 1 }
        end
      RUBY

      out, status = cli("build", "multi.rb", "--format=ir", dir: dir)
      assert status.success?, out
      assert_match(/class MultiIR/, out)
      assert_match(/var: :score/, out)
    end
  end

  # A custom font (`font :name do ... end`) registers into RubyGBA::Fonts as a side
  # effect, rather than living in the IR tree draw_text's `font:` operand just names
  # by symbol — so the emitted class has to carry the font's own definition too, or
  # lowering it in a fresh process fails looking the name up. This is the regression
  # test for exactly that gap.
  def test_format_ir_carries_a_custom_registered_font_along_with_the_tree
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "lettered.rb"), <<~RUBY)
        require "ruby_gba"
        Lettered = RubyGBA.game "LETTERED", code: "BLET", maker: "01" do
          screen :bitmap
          font :blocky do
            glyph "A", <<~ART
              ###
              #.#
              ###
            ART
          end
          draw_text "A", 0, 0, :white, font: :blocky
          halt
        end
      RUBY

      out, status = cli("build", "lettered.rb", "--format=ir", "-o", "lettered_ir.rb", dir: dir)
      assert status.success?, out
      assert_match(/Fonts\.register\(:blocky, RubyGBA::Font\.new/, File.read(File.join(dir, "lettered_ir.rb")))

      run_out, run_status = run_ruby(File.join(dir, "lettered_ir.rb"), dir: dir)
      assert run_status.success?, run_out
    end
  end
end
