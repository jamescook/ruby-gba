# frozen_string_literal: true

require "test_helper"

require "open3"
require "tmpdir"
require "rbconfig"
require "json"
require "stringio"

# End-to-end tests for the `vblank` command. These are the only tests that touch
# Thor: they run bin/vblank in a subprocess, the way a user does, so the CLI (and
# its dependency) stays out of every other test. Everything else builds ROMs through
# the library (VBlank.game / VBlank.build) with no CLI involved.
class TestCLI < Minitest::Test
  # Which Ruby to launch, asked once here. Asking reads Ruby's own table of how it was
  # built, which is not something a worker may touch — and these tests run in a pool.
  RUBY = RbConfig.ruby.freeze

  BIN = VBlank.root.join("bin/vblank").to_s
  LIB = VBlank.root.join("lib").to_s

  # Run the CLI in +dir+ and return [combined_output, Process::Status].
  private def cli(*args, dir:)
    Open3.capture2e(RUBY, BIN, *args, chdir: dir)
  end

  # Run an arbitrary Ruby file (e.g. something `build --format=ir` wrote) as its own
  # process, with the checkout's lib/ on its load path — the way a user who cloned
  # the repo, rather than installed the gem, would run it.
  private def run_ruby(path, dir:)
    Open3.capture2e(RUBY, "-I", LIB, path, chdir: dir)
  end

  def test_new_scaffolds_a_game_that_builds_and_runs
    Dir.mktmpdir do |dir|
      out, status = cli("new", "demo", dir: dir)
      assert status.success?, out
      assert File.exist?(File.join(dir, "demo.rb")), "new should write demo.rb"

      assert_match(/consoles: %i\[gba gbc\]/, File.read(File.join(dir, "demo.rb")), "the starter is for both consoles")

      build_out, build_status = cli("build", "demo.rb", dir: dir)
      assert build_status.success?, build_out
      assert_match(/Built demo\.gba \(\d+ bytes\)/, build_out)
      assert_match(/Built demo\.gbc \(\d+ bytes\)/, build_out)
      refute_match(/warning/, build_out, "the starter builds with nothing to warn about")
    end
  end

  # `ruby demo.rb` builds what `vblank build demo.rb` builds: a cartridge for each console.
  def test_running_the_starter_with_ruby_writes_a_cartridge_for_each_console
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = run_ruby("demo.rb", dir: dir)

      assert status.success?, out
      assert File.exist?(File.join(dir, "demo.gba")), out
      assert File.exist?(File.join(dir, "demo.gbc")), out
    end
  end

  def test_build_honors_the_output_path
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = cli("build", "demo.rb", "-o", "roms/custom.gba", "--console", "gba", dir: dir)
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

  # --set tells the game a setting, as text that its own `setting` line reads. A game whose
  # setting has no default only builds when --set gives it, and one given under the wrong name
  # is a friendly error naming both. (With no default there is no kind of thing to read the
  # text as, so the game reads it itself.)
  NEEDS_A_SETTING = <<~RUBY
    require "vblank"
    VBlank.game "SETS", consoles: %i[gba] do
      screen :bitmap
      var :floors, Integer(setting(:floors))
      game_loop { wait_vblank }
    end
  RUBY

  def test_set_tells_the_game_a_setting
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "sets.rb"), NEEDS_A_SETTING)

      out, status = cli("build", "sets.rb", "--set", "floors=1", dir: dir)
      assert status.success?, out

      out, status = cli("build", "sets.rb", "--set", "flors=1", dir: dir)
      refute status.success?
      assert_match(/:floors has no default, and this build did not give it\. This build gave :flors/, out)
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

  def test_inspect_refuses_a_cartridge_that_is_not_the_advances
    Dir.mktmpdir do |dir|
      rom = VBlank.build("COLOR", console: :gbc, out: StringIO.new, err: StringIO.new) { game_loop {} }
      rom.write(File.join(dir, "color.gbc"))
      out, status = cli("inspect", "color.gbc", dir: dir)
      refute status.success?
      assert_match(/color\.gbc is not a Game Boy Advance cartridge/, out)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  def test_profile_folds_in_what_the_build_made_and_what_it_cost
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = cli("build", "demo.rb", "--profile", dir: dir)
      assert status.success?, out
      assert_match(/kept in quick memory/, out, "what the build made")
      assert_match(/where your frames went/, out, "and what it cost when it ran")
    end
  end

  # A scened game with SCENE, so `build`'s content is the same across the scene tests.
  SCENED = <<~RUBY
    require "vblank"
    Scened = VBlank.game "SCENED", consoles: %i[gba], code: "BSCN", maker: "01" do
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

  # A game whose expensive state needs a particular combination can say so, instead of
  # relying on the sweep that holds one button at a time. Naming the buttons also asks
  # for the report, so there is no --profile to remember.
  def test_keys_holds_the_named_buttons_and_says_so
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "held.rb"), HELD)
      out, status = cli("build", "held.rb", "--keys", "left", "a", dir: dir)
      assert status.success?, out
      assert_match(/holding LEFT \+ A/, out)
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
    require "vblank"
    Held = VBlank.game "HELD", consoles: %i[gba], code: "BHLD", maker: "01" do
      screen :bitmap
      var :x, 0
      game_loop do
        held(:left).then { add! :x, 1 }
      end
    end
  RUBY

  def test_scene_narrows_to_one_and_an_unknown_scene_is_friendly
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "scened.rb"), SCENED)
      out, status = cli("build", "scened.rb", "--scene", "play", dir: dir)
      assert status.success?, out
      assert_match(/held in the :play scene/, out)

      bad, bad_status = cli("build", "scened.rb", "--scene", "nope", dir: dir)
      refute bad_status.success?, bad
      assert_match(/no scene called/, bad)
    end
  end

  def test_stats_reports_asset_packing_for_a_tiled_game
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "packy.rb"), <<~RUBY)
        require "vblank"
        Packy = VBlank.game "PACKY", consoles: %i[gba], code: "BPKY", maker: "01" do
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

  # ...and the other half of --stats, which the packing game never reaches: that game keeps
  # nothing in quick memory, so the line about it is skipped. This one has a real loop, so
  # there is something to move and the line gets printed.
  def test_stats_reports_what_is_kept_in_quick_memory
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "loopy.rb"), <<~RUBY)
        require "vblank"
        Loopy = VBlank.game "LOOPY", consoles: %i[gba], code: "BLPY", maker: "01" do
          screen :bitmap
          clear_screen :black
          t = var :t, 0
          game_loop do
            repeat(50) { |i| t.add! i }
            fill_rect 0, 0, 40, 8, :green
          end
        end
      RUBY
      out, status = cli("build", "loopy.rb", "--stats", dir: dir)
      assert status.success?, out
      assert_match(/Quick memory: \d+ routines? \([\d.]+K\), [\d.]+K of 32K free/, out)
    end
  end

  # `profile` is `build --profile` without the cartridge: same report, no .gba on disk.
  def test_profile_appears_in_the_command_list
    out, status = cli("help", dir: Dir.tmpdir)
    assert status.success?, out
    assert_match(/vblank profile GAME_FILE/, out)
  end

  # ...and the command it replaced is gone rather than quietly still working, since the
  # report it printed made claims this framework no longer makes.
  def test_explain_is_no_longer_a_command
    out, status = cli("explain", "demo.rb", dir: Dir.tmpdir)
    refute status.success?
    assert_match(/There is no command "explain"/, out)
  end

  def test_profile_prints_the_report_without_building_a_cartridge
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = cli("profile", "demo.rb", "--console", "gba", dir: dir)
      assert status.success?, out
      assert_match(/where your frames went/, out)
      refute File.exist?(File.join(dir, "demo.gba")), "profile should not write a .gba"
    end
  end

  # `profile --format=json` prints the same facts as data, on stdout, as one document — the
  # guardrails' prose goes to stderr so it cannot land in the middle of it.
  def test_profile_format_json_prints_one_parseable_document
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, err, status = Open3.capture3(RUBY, BIN, "profile", "demo.rb", "--console", "gba", "--format=json", chdir: dir)
      assert status.success?, out + err
      data = JSON.parse(out)
      assert_operator data["frames"], :>, 0
      refute_nil data["quick_memory"], "what the build made rides along with what it cost"
      assert_kind_of Array, data["findings"]
    end
  end

  def test_profile_rejects_an_unknown_format
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = cli("profile", "demo.rb", "--format", "bogus", dir: dir)
      refute status.success?
      assert_match(/"bogus" is not a profile format/, out)
    end
  end

  def test_profile_a_missing_game_file_is_a_friendly_error_not_a_backtrace
    Dir.mktmpdir do |dir|
      out, status = cli("profile", "nope.rb", dir: dir)
      refute status.success?, "a missing file should fail"
      assert_match(/cannot find the game file/, out)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  def test_profile_scene_holds_the_game_there_and_an_unknown_scene_is_friendly
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "scened.rb"), SCENED)
      out, status = cli("profile", "scened.rb", "--scene", "play", dir: dir)
      assert status.success?, out
      assert_match(/held in the :play scene/, out)

      bad, bad_status = cli("profile", "scened.rb", "--scene", "nope", dir: dir)
      refute bad_status.success?, bad
      assert_match(/no scene called/, bad)
    end
  end

  def test_profile_keys_holds_the_named_buttons_and_says_so
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "held.rb"), HELD)
      out, status = cli("profile", "held.rb", "--keys", "left", "a", dir: dir)
      assert status.success?, out
      assert_match(/holding LEFT \+ A/, out)
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
      assert_match(/VBlank::IR::Nodes\.build/, out)
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

  # A game that does not say which consoles it is for does not build, and the command says
  # what to write.
  def test_build_refuses_a_game_that_names_no_console
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "silent.rb"), <<~GAME)
        require "vblank"
        VBlank.game("SILENT") do
          game_loop { clear_screen :blue }
        end
      GAME
      out, status = cli("build", "silent.rb", dir: dir)

      refute status.success?, out
      assert_match(/SILENT does not say which consoles it is for/, out)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
      assert_empty Dir.children(dir) - ["silent.rb"], "no cartridge is written"
    end
  end

  BOTH = <<~GAME
    require "vblank"
    VBlank.game("BOTH", consoles: %i[gba gbc]) do
      x = var :x, screen_width / 2
      game_loop { x.add! 1 }
    end
  GAME

  ADVANCE_ONLY = <<~GAME
    require "vblank"
    VBlank.game("ADVANCE", consoles: %i[gba]) do
      game_loop { clear_screen :blue }
    end
  GAME

  private def assert_color_cartridge(path)
    cartridge = File.binread(path)
    assert_equal VBlank::Console::GBCHardware::CGB_ONLY, cartridge.getbyte(VBlank::Console::GBCHardware::CGB_FLAG_AT),
                 "the cartridge says it is for a Game Boy Color"
  end

  # A game for both consoles builds a cartridge for each, side by side, with nothing said.
  def test_build_writes_a_cartridge_for_each_console_the_game_names
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "both.rb"), BOTH)
      out, status = cli("build", "both.rb", dir: dir)

      assert status.success?, out
      assert_match(/Built both\.gba \(\d+ bytes\)/, out)
      assert_match(/Built both\.gbc \(\d+ bytes\)/, out)
      assert VBlank::Cartridge::ROM.header?(File.binread(File.join(dir, "both.gba")))
      assert_color_cartridge(File.join(dir, "both.gbc"))
    end
  end

  # --console builds one of them; a console the game is not for is refused, saying what to write.
  def test_build_console_builds_the_one_cartridge_it_names
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "both.rb"), BOTH)
      out, status = cli("build", "both.rb", "--console", "gbc", dir: dir)

      assert status.success?, out
      assert_color_cartridge(File.join(dir, "both.gbc"))
      refute File.exist?(File.join(dir, "both.gba")), "only the Color's is built"

      File.write(File.join(dir, "advance.rb"), ADVANCE_ONLY)
      refused, refused_status = cli("build", "advance.rb", "--console", "gbc", dir: dir)
      refute refused_status.success?
      assert_match(/consoles: %i\[gba gbc\]/, refused)
      refute_match(/\.rb:\d+:in/, refused, "should not leak a backtrace")
    end
  end

  COLOR_ONLY = <<~GAME
    require "vblank"
    VBlank.game("COLORONLY", consoles: %i[gbc]) do
      game_loop { clear_screen :blue }
    end
  GAME

  # A web page and a desktop program draw the Advance's screen, so they are made from the
  # Advance's game, and a game for the Color alone is refused saying what to write.
  def test_web_and_native_refuse_a_game_for_the_color_alone
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "coloronly.rb"), COLOR_ONLY)

      %w[web native ir].each do |format|
        out, status = cli("build", "coloronly.rb", "--format", format, dir: dir)

        refute status.success?, "#{format}: #{out}"
        assert_match(/COLORONLY is not for the Game Boy Advance/i, out, format)
        assert_match(/consoles: %i\[gbc gba\]/, out, format)
        refute_match(/\.rb:\d+:in/, out, "#{format}: should not leak a backtrace")
      end
      assert_empty Dir.children(dir) - ["coloronly.rb"], "nothing is written"
    end
  end

  # `vblank run` plays the game as Ruby in a window: here SDL's dummy drivers, which make windows
  # nobody sees and sound nobody hears. It says which Ruby plays it, and when it stops, how fast
  # it went.
  def test_run_plays_the_game_in_a_window_and_says_how_fast
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = run_in_dummy_window(dir, "demo.rb", "--pictures", "5")

      assert status.success?, out
      assert_match(/DEMO for the Game Boy Advance in Ruby #{Regexp.escape(RUBY_VERSION)} with (YJIT|ZJIT|no JIT)\./o, out)
      assert_match(/DEMO is for the Game Boy Advance and the Game Boy Color\. This plays it as the Game Boy Advance\. To play it as the Game Boy Color, add --console gbc\./, out)
      assert_match(/Showed 5 pictures in [\d.]+ seconds/, out)
      assert_match(/The console shows 59\.7 a second/, out)
    end
  end

  # A game that draws a picture and stops itself keeps it in the window, and the command says the
  # game stopped itself rather than how fast it went.
  def test_run_says_a_game_stopped_itself
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "still.rb"), <<~GAME)
        require "vblank"
        VBlank.game("STILL", consoles: %i[gba]) do
          clear_screen :blue
          halt
        end
      GAME
      out, status = run_in_dummy_window(dir, "still.rb", "--pictures", "3")

      assert status.success?, out
      assert_match(/STILL stopped itself after 0 frames\. Its last picture stayed in the window\./, out)
      refute_match(/a second\./, out)
    end
  end

  # --format=ruby writes the game as one Ruby file that plays in a window with Ruby alone: copied
  # to a folder with nothing of vblank's, run by a Ruby that cannot load the gem, it plays.
  def test_build_format_ruby_writes_a_game_that_plays_with_ruby_alone
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = cli("build", "demo.rb", "--format=ruby", "--console", "gba", dir: dir)
      assert status.success?, out
      assert_match(/Built .*demo-ruby\.rb/, out)

      Dir.mktmpdir do |elsewhere|
        FileUtils.cp(File.join(dir, "demo-ruby.rb"), elsewhere)
        alone = { "SDL_VIDEODRIVER" => "dummy", "SDL_AUDIODRIVER" => "dummy", "RUBYOPT" => nil, "RUBYLIB" => nil,
                  "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil, "RUBY_YJIT_ENABLE" => nil }
        played, status = Open3.capture2e(alone, RUBY, "demo-ruby.rb", "--pictures", "3", chdir: elsewhere)
        skip played.lines.first.chomp if played.include?("cannot find SDL3")

        assert status.success?, played
        assert_match(/Playing DEMO/, played)
        assert_match(/Showed 3 pictures/, played)
      end
    end
  end

  # --record-sound keeps what the game handed the speaker, to listen to afterwards.
  def test_run_records_the_sound_to_a_wav
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = run_in_dummy_window(dir, "demo.rb", "--pictures", "10", "--console", "gba", "--record-sound", "heard.wav")

      assert status.success?, out
      wav = File.join(dir, "heard.wav")
      assert File.exist?(wav), out
      assert_equal "RIFF", File.binread(wav, 4)
      assert_match(/The sound the game made is in heard\.wav\./, out)
    end
  end

  # YJIT is on unless --no-yjit says not, so the speed can be measured both ways.
  def test_run_plays_without_yjit_when_told
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = run_in_dummy_window(dir, "demo.rb", "--pictures", "3", "--no-yjit", "--console", "gba")

      assert status.success?, out
      assert_match(/in Ruby #{Regexp.escape(RUBY_VERSION)} with no JIT\./o, out)
    end
  end

  # A game for the Color alone plays as the Color, on a window the size of its screen.
  def test_run_plays_a_game_for_the_color_alone_as_the_color
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "coloronly.rb"), COLOR_ONLY)
      out, status = run_in_dummy_window(dir, "coloronly.rb", "--pictures", "3")

      assert status.success?, out
      assert_match(/COLORONLY for the Game Boy Color/, out)
      assert_match(/Showed 3 pictures/, out)
    end
  end

  # A game for both consoles plays as the one --console names.
  def test_run_plays_the_console_said
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = run_in_dummy_window(dir, "demo.rb", "--console", "gbc", "--pictures", "3")

      assert status.success?, out
      assert_match(/DEMO for the Game Boy Color/, out)
      refute_match(/This plays it as/, out, "the console was said, so there is nothing to tell")
    end
  end

  # A console the game does not name is refused in words, before any window opens.
  def test_run_refuses_a_console_the_game_is_not_for
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "coloronly.rb"), COLOR_ONLY)
      out, status = cli("run", "coloronly.rb", "--console", "gba", dir: dir)

      refute status.success?, out
      assert_match(/COLORONLY/, out)
      assert_match(/Game Boy Advance/, out)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  # `vblank run` on SDL's dummy drivers, skipped where SDL3 is not installed.
  private def run_in_dummy_window(dir, *args)
    drivers = { "SDL_VIDEODRIVER" => "dummy", "SDL_AUDIODRIVER" => "dummy", "RUBY_YJIT_ENABLE" => nil }
    out, status = Open3.capture2e(drivers, RUBY, BIN, "run", *args, chdir: dir)
    skip out.lines.first.chomp if out.include?("cannot find SDL3")
    [out, status]
  end

  # When every console's build fails for one reason, it is said once, with no advice about
  # leaving a console out: the game itself is what needs changing.
  def test_build_says_a_reason_every_console_shares_once
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "broken.rb"), <<~GAME)
        require "vblank"
        VBlank.game("BROKEN", consoles: %i[gba gbc]) do
          var :floors, Integer(setting(:floors))
          game_loop { clear_screen :blue }
        end
      GAME
      out, status = cli("build", "broken.rb", "--set", "flors=1", dir: dir)

      refute status.success?
      assert_equal 1, out.scan(/flors/).size, out
      refute_match(/take :/, out)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  # A measuring the command refuses comes after every cartridge is written, so a bad --scene
  # costs the profile and never a cartridge.
  def test_build_writes_every_cartridge_before_a_refused_profile
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "both.rb"), BOTH)
      out, status = cli("build", "both.rb", "--scene", "nope", dir: dir)

      refute status.success?
      assert File.exist?(File.join(dir, "both.gba")), out
      assert File.exist?(File.join(dir, "both.gbc")), out
    end
  end

  # A profile runs one cartridge, so a game for two consoles is asked which.
  def test_profile_asks_which_console_for_a_game_of_two
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "both.rb"), BOTH)
      out, status = cli("profile", "both.rb", dir: dir)

      refute status.success?
      assert_match(/BOTH is for the Game Boy Advance and the Game Boy Color/, out)
      assert_match(/--console gba or --console gbc/, out)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  # --format=gbc was how a Color cartridge was asked for before --console; it says what to write now.
  def test_format_gbc_is_refused_naming_console
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "both.rb"), BOTH)
      out, status = cli("build", "both.rb", "--format", "gbc", dir: dir)

      refute status.success?
      assert_match(/--console gbc/, out)
    end
  end

  # --output names one file, so a game for two consoles needs --console beside it.
  def test_build_output_for_a_game_of_two_consoles_needs_console
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "both.rb"), BOTH)
      out, status = cli("build", "both.rb", "-o", "game.gba", dir: dir)

      refute status.success?
      assert_match(/--console gba or --console gbc/, out)
      refute File.exist?(File.join(dir, "game.gba"))

      built, built_status = cli("build", "both.rb", "-o", "game.gba", "--console", "gba", dir: dir)
      assert built_status.success?, built
      assert File.exist?(File.join(dir, "game.gba"))
    end
  end

  # A game for both consoles that the Color cannot play still gets its Advance cartridge. The
  # command then ends as a failure, in the build's own words and with the two ways to stop
  # asking for the Color's: no backtrace under the words, and no Color cartridge written.
  def test_build_writes_the_advance_cartridge_when_the_color_refuses_and_says_how_to_leave_it_out
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "shoulders.rb"), <<~GAME)
        require "vblank"
        VBlank.game("SHOULDERS", consoles: %i[gba gbc]) do
          count = var :count, 0
          game_loop { held(:l).then { count.add! 1 } }
        end
      GAME
      out, status = cli("build", "shoulders.rb", dir: dir)

      refute status.success?, out
      assert_match(/Built shoulders\.gba/, out)
      assert_match(/no shoulder buttons/, out)
      assert_match(/SHOULDERS was not built for the Game Boy Color/, out)
      assert_match(/take :gbc out of consoles:/, out)
      assert_match(/--console gba/, out)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
      assert File.exist?(File.join(dir, "shoulders.gba"))
      refute File.exist?(File.join(dir, "shoulders.gbc"))
    end
  end

  # The same when it is the Color's lowering that refuses, after the checks have passed. Asked
  # for the Color's alone, it does not suggest asking for the other.
  def test_build_console_gbc_refuses_what_the_color_lowering_cannot_make_without_a_backtrace
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "again.rb"), <<~GAME)
        require "vblank"
        VBlank.game("AGAIN", consoles: %i[gba gbc]) do
          func(:again) { call :again }
          game_loop { call :again }
        end
      GAME
      out, status = cli("build", "again.rb", "--console", "gbc", dir: dir)

      refute status.success?, out
      assert_match(/can call itself again/, out)
      assert_match(/take :gbc out of consoles:/, out)
      refute_match(/--console gba/, out)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  # And when it is the Advance's lowering: three timers whose ticks are read take six of the
  # Advance's four hardware timers, which only the lowering counts.
  def test_build_refuses_what_the_advance_lowering_cannot_make_without_a_backtrace
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "timers.rb"), <<~GAME)
        require "vblank"
        VBlank.game("TIMERS", consoles: %i[gba]) do
          screen :bitmap
          %i[a b c].each do |name|
            t = timer name, per_second: 60
            var :"snap_\#{name}", 0
            set! :"snap_\#{name}", t.ticks
          end
          halt
        end
      GAME
      out, status = cli("build", "timers.rb", dir: dir)

      refute status.success?, out
      assert_match(/more hardware timers than the GBA has/, out)
      refute File.exist?(File.join(dir, "timers.gba")), "no cartridge is written"
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  # And when the game keeps more than the Color has memory for.
  def test_build_refuses_a_game_too_big_for_the_colors_memory_without_a_backtrace
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "hoard.rb"), <<~GAME)
        require "vblank"
        VBlank.game("HOARD", consoles: %i[gba gbc]) do
          trail = list :trail, capacity: 6000
          game_loop { trail.push 1 }
        end
      GAME
      out, status = cli("build", "hoard.rb", "--console", "gbc", dir: dir)

      refute status.success?, out
      assert_match(/:trail/, out)
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  # And when the game's tables are more than the part of the Color's cartridge always in view
  # holds: the refusal names the tables, not the linker's sections. A big table is kept in banks,
  # so it takes many small ones, which stay in view, to fill that part.
  def test_build_refuses_a_game_too_big_for_the_colors_cartridge_without_a_backtrace
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "atlas.rb"), <<~GAME)
        require "vblank"
        VBlank.game("ATLAS", consoles: %i[gba gbc]) do
          at = var :at, 0
          height = var :height, 0
          heights = Array.new(20) { |n| table :"heights_\#{n}", Array.new(1000) { |i| (i + n) % 100 }, width: :byte }
          game_loop do
            heights.each { |t| height.set! t[at] }
            at.add! 1
          end
        end
      GAME
      out, status = cli("build", "atlas.rb", "--console", "gbc", dir: dir)

      refute status.success?, out
      assert_match(/does not fit in a Game Boy Color cartridge/, out)
      assert_match(/tables/, out)
      refute_match(/section/, out, "the linker's own words stay inside")
      refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
    end
  end

  # A game built for the web is one page beside it, holding the game and what plays it, with
  # nothing to fetch.
  def test_format_web_writes_one_page_that_plays_the_game
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = cli("build", "demo.rb", "--format", "web", dir: dir)
      assert status.success?, out

      page = File.read(File.join(dir, "demo.html"), encoding: Encoding::UTF_8)
      assert_match(/<canvas id="screen"/, page)
      assert_match(/<script>/, page, "the game is in the page")
      refute_match(/<script src=/, page, "nothing is fetched")
    end
  end

  # --template writes the page from a template of the author's own, and a template that leaves the
  # game out stops the build in plain words.
  def test_format_web_writes_the_page_from_the_template_given
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      File.write(File.join(dir, "mine.html.erb"), "<!doctype html>\n<h1>My <%= title %></h1>\n<%= game %>\n")
      out, status = cli("build", "demo.rb", "--format", "web", "--template", "mine.html.erb", dir: dir)
      assert status.success?, out
      assert_match(/<h1>My /, File.read(File.join(dir, "demo.html"), encoding: Encoding::UTF_8))

      File.write(File.join(dir, "empty.html.erb"), "<p>nothing</p>\n")
      out, status = cli("build", "demo.rb", "--format", "web", "--template", "empty.html.erb", dir: dir)
      refute status.success?, "a template without the game should fail"
      assert_match(/does not write the game/, out)
    end
  end

  # --js module writes the game as an ES module beside it in place of the page; a kind of
  # JavaScript there is none of is refused in the command's own words for the ones there are.
  def test_format_web_writes_the_kind_of_javascript_asked_for
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = cli("build", "demo.rb", "--format", "web", "--js", "module", dir: dir)
      assert status.success?, out
      assert File.exist?(File.join(dir, "demo.mjs")), "the module is written beside the game"
      refute File.exist?(File.join(dir, "demo.html")), "the module is written in place of the page"

      out, status = cli("build", "demo.rb", "--format", "web", "--js", "script", dir: dir)
      assert status.success?, out
      assert File.exist?(File.join(dir, "demo.js")), "the classic script is written beside the game"
      out, status = cli("build", "demo.rb", "--format", "web", "--js", "script", "--global", "starter", dir: dir)
      assert status.success?, out
      assert_includes File.read(File.join(dir, "demo.js"), encoding: Encoding::UTF_8), '"starter"', "the name --global gave"

      out, status = cli("build", "demo.rb", "--format", "web", "--js", "wasm", dir: dir)
      refute status.success?, "an unknown kind of JavaScript should fail"
      assert_match(/page, module/, out)
    end
  end

  # An option that does nothing where it is given is refused in plain words, rather than left to
  # look as if it did something.
  def test_web_options_given_where_they_do_nothing_are_refused
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      File.write(File.join(dir, "mine.html.erb"), "<%= game %>\n")
      {
        ["--format", "web", "--global", "demo"] => /--global works only with --js=script/,
        ["--format", "web", "--js", "module", "--template", "mine.html.erb"] => /--template works only with the page/,
        ["--js", "module"] => /works only with --format=web/,
        ["--data", "separate"] => /works only with --format=web/
      }.each do |options, said|
        out, status = cli("build", "demo.rb", *options, dir: dir)
        refute status.success?, "#{options.join(' ')} should fail"
        assert_match said, out
      end
    end
  end

  # --data separate writes a game's big tables to a data file beside what it builds; left alone,
  # they stay in the one file.
  def test_format_web_writes_big_tables_to_a_data_file_when_asked
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "tabled.rb"), <<~RUBY)
        VBlank.game "TABLED", consoles: %i[gba] do
          screen :bitmap
          places = table :places, (0...300).map { |i| i % 200 }, width: :half
          n = var :n, 0
          game_loop do
            n.add! 1
            draw_rect_at places[n], 20, 4, 4, :green
          end
        end
      RUBY
      out, status = cli("build", "tabled.rb", "--format", "web", dir: dir)
      assert status.success?, out
      refute File.exist?(File.join(dir, "tabled.data")), "the data stays in the page unless asked"

      out, status = cli("build", "tabled.rb", "--format", "web", "--js", "module", "--data", "separate", dir: dir)
      assert status.success?, out
      assert File.exist?(File.join(dir, "tabled.data")), "the big table goes beside the module"
    end
  end

  # A computer there is no build for is refused before anything is built, in the command's own
  # words for the ones there are.
  def test_format_native_rejects_an_unknown_target
    Dir.mktmpdir do |dir|
      cli("new", "demo", dir: dir)
      out, status = cli("build", "demo.rb", "--format", "native", "--target", "amiga", dir: dir)
      refute status.success?, "an unknown computer should fail"
      assert_match(/no build for amiga/, out)
      assert_match(/windows, linux, linux-arm/, out)
      refute_match(/Building/, out, "nothing is built")
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
        require "vblank"
        require_relative "extra_state"

        Multi = VBlank.game "MULTI", consoles: %i[gba], code: "BMLT", maker: "01" do
          screen :bitmap
          ExtraState.declare(self)
          game_loop { add! :score, 1 }
        end
      RUBY

      out, status = cli("build", "multi.rb", "--format=ir", dir: dir)
      assert status.success?, out
      assert_match(/class MultiIR/, out)
      assert_match(/var: :score/, out)
    end
  end

  # A custom font (`font :name do ... end`) registers into VBlank::Graphics::Fonts as a side
  # effect, rather than living in the IR tree draw_text's `font:` operand just names
  # by symbol — so the emitted class has to carry the font's own definition too, or
  # lowering it in a fresh process fails looking the name up. This is the regression
  # test for exactly that gap.
  def test_format_ir_carries_a_custom_registered_font_along_with_the_tree
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "lettered.rb"), <<~RUBY)
        require "vblank"
        Lettered = VBlank.game "LETTERED", consoles: %i[gba], code: "BLET", maker: "01" do
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
      assert_match(/:font, name: :blocky, font: VBlank::Graphics::Font\.new/,
                   File.read(File.join(dir, "lettered_ir.rb")),
                   "the game's own font comes back inside the tree, not as a separate registration")

      run_out, run_status = run_ruby(File.join(dir, "lettered_ir.rb"), dir: dir)
      assert run_status.success?, run_out
    end
  end
end
