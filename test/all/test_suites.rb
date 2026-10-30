# frozen_string_literal: true

require "test_helper"

# `rake test` plays the suite once for each lowering: the GBA lowering's run (the interpreter,
# with the cartridge checked in the emulator), the native lowering's (the game built as C,
# checked against the interpreter), the JavaScript lowering's (the game built as JavaScript,
# checked the same way) and the Game Boy Color lowering's (the game built as a Game Boy Color
# cartridge, played in the emulator and checked the same way). Every test is played by all four,
# except a test of one lowering's own output, which lives in a folder that lowering owns. Its
# other side is test_native_suite.rb, test_js_suite.rb and test_gbc_suite.rb, in those lowerings'
# folders, which fail if another run ever plays them.
class TestSuitesSplit < Minitest::Test
  PLAYERS = [Reference, CheckedPlayer, VBlank::IR::Backends::Native::CheckedRun,
             VBlank::IR::Backends::Native::HeadlessRun, VBlank::Testing::JSCheckedPlayer,
             VBlank::IR::Backends::JS::CheckedRun, VBlank::IR::Backends::JS::HeadlessRun,
             VBlank::Testing::RubyCheckedPlayer, VBlank::IR::Backends::Ruby::CheckedRun,
             VBlank::IR::Backends::Ruby::HeadlessRun, VBlank::IR::Backends::GBC::HeadlessRun,
             # Every console whose own cartridge a run plays: its player, and the checked run it
             # is made from.
             *VBlank::Console.kits.grep(VBlank::Console::CheckedKit).flat_map do |kit|
               [VBlank::Testing::CartridgeCheckedPlayer.for(kit.name), kit.checked_run]
             end].freeze
  # SNES::HeadlessRun is left out: it also takes `watch_picture:`, which only the Super Nintendo
  # lowering's own tests ask for, and a test is never handed it as its player.

  # A test of one lowering's own output — the ARM a cartridge is made of, the cartridge played in
  # the emulator, the C the native lowering writes — lives in a folder that lowering owns, and
  # the other lowering's run never loads it. Every other file is loaded by both.
  def test_a_lowering_run_leaves_out_the_other_lowerings_folders
    native_run = files_for(:native)
    interpreter_run = files_for(:gba)

    assert_includes native_run, "test/lowering/native/vblank/ir/backends/native/test_native_picture.rb"
    refute_includes native_run, "test/lowering/gba/vblank/ir/backends/gba/test_asm.rb"
    refute_includes native_run, "test/lowering/gba/vblank/playthroughs/test_playthrough.rb"
    refute_includes native_run, "test/lowering/gba/vblank/diagnostics/test_verifier.rb"
    assert_includes interpreter_run, "test/lowering/gba/vblank/ir/backends/gba/test_asm.rb"
    refute_includes interpreter_run, "test/lowering/native/vblank/ir/backends/native/test_native_picture.rb"
    shared = "test/all/vblank/dsl/test_pool_walk_order.rb"
    assert_includes native_run, shared
    assert_includes interpreter_run, shared
  end

  def test_the_js_run_leaves_out_the_other_lowerings_folders_and_keeps_its_own
    js_run = files_for(:js)

    assert_includes js_run, "test/lowering/js/vblank/ir/backends/js/test_js_suite.rb"
    assert_includes js_run, "test/all/vblank/dsl/test_pool_walk_order.rb"
    refute_includes js_run, "test/lowering/native/vblank/ir/backends/native/test_native_picture.rb"
    refute_includes js_run, "test/lowering/gba/vblank/ir/backends/gba/test_asm.rb"
    refute_includes files_for(:native), "test/lowering/js/vblank/ir/backends/js/test_js_suite.rb"
    refute_includes files_for(:gba), "test/lowering/js/vblank/ir/backends/js/test_js_suite.rb"
  end

  def test_the_gbc_run_leaves_out_the_other_lowerings_folders_and_keeps_its_own
    gbc_run = files_for(:gbc)

    assert_includes gbc_run, "test/lowering/gbc/vblank/ir/backends/gbc/test_gbc_suite.rb"
    assert_includes gbc_run, "test/all/vblank/dsl/test_pool_walk_order.rb"
    refute_includes gbc_run, "test/lowering/js/vblank/ir/backends/js/test_js_suite.rb"
    refute_includes gbc_run, "test/lowering/gba/vblank/ir/backends/gba/test_asm.rb"
    %i[gba native js].each { |other| refute_includes files_for(other), "test/lowering/gbc/vblank/ir/backends/gbc/test_gbc_suite.rb" }
  end

  # A test of what only the Advance can do — fading part of the screen, a recording in a song —
  # is played by every lowering that plays an Advance game, and the Color's run never loads it.
  def test_the_advance_folder_is_loaded_by_every_run_of_an_advance_game_and_not_the_colors
    advance_test = Dir.glob("#{TestSuites.console_dir(:gba)}/**/test_*.rb").first

    refute_nil advance_test, "the Advance's folder holds tests"
    %i[gba native js ruby].each { |lowering| assert_includes files_for(lowering), advance_test, lowering }
    refute_includes files_for(:gbc), advance_test
  end

  # A test makes its player and runs a game the same way whichever lowering hands it the player,
  # so every player takes the interpreter's words. One added to the interpreter and not the
  # others fails here, on every run, rather than on the first native run that meets it.
  def test_every_player_takes_the_interpreters_words
    %i[initialize run].each do |method|
      words = PLAYERS.map { |player| [player, keywords_of(player.instance_method(method))] }

      assert_equal 1, words.map(&:last).uniq.size, "#{method} takes different words: #{words.to_h.inspect}"
    end
  end

  # Each lowering's record names the class its run's game_player makes, and that class is one
  # of the players held to the interpreter's words above.
  def test_every_run_names_a_player_that_takes_the_interpreters_words
    VBlank::Testing::Lowering::RUNS.each do |run|
      assert_includes PLAYERS, run.player_class, run.name
    end
  end

  # The guard for a test native cannot play yet skips on the native lowering's run and does
  # nothing on the GBA lowering's.
  def test_the_native_guard_skips_on_the_native_run_alone
    if VBlank::Testing.native?
      assert_raises(Minitest::Skip) { skip_on_native "only says something on a native run" }
    else
      skip_on_native "only says something on a native run"
      pass
    end
  end

  def test_the_js_guard_skips_on_the_js_run_alone
    if VBlank::Testing.javascript?
      assert_raises(Minitest::Skip) { skip_on_js "only says something on a JavaScript run" }
    else
      skip_on_js "only says something on a JavaScript run"
      pass
    end
  end

  def test_the_ruby_guard_skips_on_the_ruby_run_alone
    if VBlank::Testing.lowering == :ruby
      assert_raises(Minitest::Skip) { skip_on_ruby "only says something on a Ruby run" }
    else
      skip_on_ruby "only says something on a Ruby run"
      pass
    end
  end

  def test_the_gbc_guard_skips_on_the_gbc_run_alone
    if VBlank::Testing.gbc?
      assert_raises(Minitest::Skip) { skip_on_gbc "only says something on a Game Boy Color run" }
    else
      skip_on_gbc "only says something on a Game Boy Color run"
      pass
    end
  end

  # EVERY TEST FILE SITS IN A FOLDER THAT SAYS WHICH RUNS LOAD IT (test/support/suites.rb): test/all,
  # or the folder of a console or a lowering some run plays. A file anywhere else would be loaded
  # by every run with nobody having said so, and a folder named for no run by none.
  def test_every_test_file_sits_in_a_folder_that_says_which_runs_load_it
    consoles = VBlank::Testing::Lowering::RUNS.map(&:console).uniq
    lowerings = VBlank::Testing::Lowering::NAMES
    homes = [TestSuites::ALL_DIR, TestSuites::INTERPRETER_DIR, *consoles.map { |c| TestSuites.console_dir(c) },
             *lowerings.map { |l| TestSuites.lowering_dir(l) }]
    stray = TestSuites.all_files(desktop: true).reject { |path| homes.any? { |home| path.start_with?("#{home}/") } }

    assert_empty stray, "each test file goes in #{TestSuites::ALL_DIR}/, #{TestSuites::INTERPRETER_DIR}/, " \
                        "test/console/<console>/ or test/lowering/<lowering>/"
  end

  # A BUILD IN A TEST SAYS WHERE IT PRINTS. VBlank.build and build_rom print the game's warnings
  # (and a debug_halt's reminder) to the process's own streams unless told otherwise, which is
  # right for a person building a game and wrong in a run of the suite, whose output is a line of
  # dots. So every build in a test passes `err:` — a StringIO to read the words back, or nil.
  def test_every_build_in_a_test_says_where_it_prints
    # A game's own suite (the fixtures), a debugging script, and this file, whose pattern names the calls.
    skipped = ["test/debug_render.rb", "test/all/test_suites.rb"]
    unsaid = Dir.glob("test/**/*.rb").reject { |path| path.start_with?("test/fixtures/") || skipped.include?(path) }
                .flat_map { |path| builds_naming_no_stream(path) }

    assert_empty unsaid, "give each of these builds `err:` (a StringIO, or nil), and `out:` too"
  end

  private

  # "path:line" for each VBlank.build or build_rom call in +path+ whose arguments name no `err:`.
  def builds_naming_no_stream(path)
    text = File.read(path)
    text.to_enum(:scan, /VBlank\.build\(|\.build_rom(?!\w)/).filter_map do
      at = Regexp.last_match.begin(0)
      opened = Regexp.last_match.end(0)
      args = if text[opened - 1] == "(" then text[opened...closing_paren(text, opened - 1)]
             elsif text[opened] == "(" then text[(opened + 1)...closing_paren(text, opened)]
             else ""
             end
      "#{path}:#{text[0...at].count("\n") + 1}" unless args.include?("err:")
    end
  end

  # Where the parenthesis opened at +from+ in +text+ closes, skipping quoted strings.
  def closing_paren(text, from)
    depth = 0
    quote = nil
    (from...text.length).each do |i|
      c = text[i]
      if quote then quote = nil if c == quote && text[i - 1] != "\\"
      elsif ['"', "'"].include?(c) then quote = c
      elsif c == "(" then depth += 1
      elsif c == ")" && (depth -= 1).zero? then return i
      end
    end
    text.length
  end

  # The files +lowering+'s run loads, worked out as the Rakefile has the library's rake tasks do it.
  def files_for(lowering)
    VBlank::Testing::Lowering.files_for(lowering, files: TestSuites.all_files, folders: TestSuites::LOWERING_FOLDERS)
  end

  def keywords_of(method) = method.parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }.sort
end
