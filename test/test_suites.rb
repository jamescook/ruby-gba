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

    assert_includes native_run, "test/vblank/ir/backends/native/test_native_picture.rb"
    refute_includes native_run, "test/vblank/ir/backends/gba/test_asm.rb"
    refute_includes native_run, "test/vblank/playthroughs/test_playthrough.rb"
    refute_includes native_run, "test/vblank/diagnostics/test_verifier.rb"
    assert_includes interpreter_run, "test/vblank/ir/backends/gba/test_asm.rb"
    refute_includes interpreter_run, "test/vblank/ir/backends/native/test_native_picture.rb"
    shared = "test/vblank/dsl/test_pool_walk_order.rb"
    assert_includes native_run, shared
    assert_includes interpreter_run, shared
  end

  def test_the_js_run_leaves_out_the_other_lowerings_folders_and_keeps_its_own
    js_run = files_for(:js)

    assert_includes js_run, "test/vblank/ir/backends/js/test_js_suite.rb"
    assert_includes js_run, "test/vblank/dsl/test_pool_walk_order.rb"
    refute_includes js_run, "test/vblank/ir/backends/native/test_native_picture.rb"
    refute_includes js_run, "test/vblank/ir/backends/gba/test_asm.rb"
    refute_includes files_for(:native), "test/vblank/ir/backends/js/test_js_suite.rb"
    refute_includes files_for(:gba), "test/vblank/ir/backends/js/test_js_suite.rb"
  end

  def test_the_gbc_run_leaves_out_the_other_lowerings_folders_and_keeps_its_own
    gbc_run = files_for(:gbc)

    assert_includes gbc_run, "test/vblank/ir/backends/gbc/test_gbc_suite.rb"
    assert_includes gbc_run, "test/vblank/dsl/test_pool_walk_order.rb"
    refute_includes gbc_run, "test/vblank/ir/backends/js/test_js_suite.rb"
    refute_includes gbc_run, "test/vblank/ir/backends/gba/test_asm.rb"
    %i[gba native js].each { |other| refute_includes files_for(other), "test/vblank/ir/backends/gbc/test_gbc_suite.rb" }
  end

  # A test of what only the Advance can do — fading part of the screen, a recording in a song —
  # is played by every lowering that plays an Advance game, and the Color's run never loads it.
  def test_the_advance_folder_is_loaded_by_every_run_of_an_advance_game_and_not_the_colors
    advance_test = Dir.glob("#{TestSuites::ADVANCE_DIR}/**/test_*.rb").first

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

  private

  # The files +lowering+'s run loads, worked out as the Rakefile has the library's rake tasks do it.
  def files_for(lowering)
    VBlank::Testing::Lowering.files_for(lowering, files: TestSuites.all_files, folders: TestSuites::LOWERING_FOLDERS)
  end

  def keywords_of(method) = method.parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }.sort
end
