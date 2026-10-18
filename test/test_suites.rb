# frozen_string_literal: true

require "test_helper"

# `rake test` plays the suite once for each lowering: the GBA lowering's run (the interpreter,
# with the cartridge checked in the emulator), the native lowering's (the game built as C,
# checked against the interpreter) and the JavaScript lowering's (the game built as JavaScript,
# checked the same way). Every test is played by all three, except a test of one lowering's own
# output, which lives in a folder that lowering owns. Its other side is test_native_suite.rb and
# test_js_suite.rb, in those lowerings' folders, which fail if another run ever plays them.
class TestSuitesSplit < Minitest::Test
  PLAYERS = [Reference, CheckedPlayer, RubyGBA::IR::Backends::Native::CheckedRun,
             RubyGBA::IR::Backends::Native::HeadlessRun, RubyGBA::Testing::JSCheckedPlayer,
             RubyGBA::IR::Backends::JS::CheckedRun, RubyGBA::IR::Backends::JS::HeadlessRun].freeze

  # A test of one lowering's own output — the ARM a cartridge is made of, the cartridge played in
  # the emulator, the C the native lowering writes — lives in a folder that lowering owns, and
  # the other lowering's run never loads it. Every other file is loaded by both.
  def test_a_lowering_run_leaves_out_the_other_lowerings_folders
    native_run = files_for(:native)
    interpreter_run = files_for(:gba)

    assert_includes native_run, "test/ruby_gba/ir/backends/native/test_native_picture.rb"
    refute_includes native_run, "test/ruby_gba/ir/backends/gba/test_asm.rb"
    refute_includes native_run, "test/ruby_gba/playthroughs/test_playthrough.rb"
    refute_includes native_run, "test/ruby_gba/diagnostics/test_verifier.rb"
    assert_includes interpreter_run, "test/ruby_gba/ir/backends/gba/test_asm.rb"
    refute_includes interpreter_run, "test/ruby_gba/ir/backends/native/test_native_picture.rb"
    shared = "test/ruby_gba/dsl/test_pool_walk_order.rb"
    assert_includes native_run, shared
    assert_includes interpreter_run, shared
  end

  def test_the_js_run_leaves_out_the_other_lowerings_folders_and_keeps_its_own
    js_run = files_for(:js)

    assert_includes js_run, "test/ruby_gba/ir/backends/js/test_js_suite.rb"
    assert_includes js_run, "test/ruby_gba/dsl/test_pool_walk_order.rb"
    refute_includes js_run, "test/ruby_gba/ir/backends/native/test_native_picture.rb"
    refute_includes js_run, "test/ruby_gba/ir/backends/gba/test_asm.rb"
    refute_includes files_for(:native), "test/ruby_gba/ir/backends/js/test_js_suite.rb"
    refute_includes files_for(:gba), "test/ruby_gba/ir/backends/js/test_js_suite.rb"
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

  # The guard for a test native cannot play yet skips on the native lowering's run and does
  # nothing on the GBA lowering's.
  def test_the_native_guard_skips_on_the_native_run_alone
    if RubyGBA::Testing.native?
      assert_raises(Minitest::Skip) { skip_on_native "only says something on a native run" }
    else
      skip_on_native "only says something on a native run"
      pass
    end
  end

  def test_the_js_guard_skips_on_the_js_run_alone
    if RubyGBA::Testing.javascript?
      assert_raises(Minitest::Skip) { skip_on_js "only says something on a JavaScript run" }
    else
      skip_on_js "only says something on a JavaScript run"
      pass
    end
  end

  private

  # The files +lowering+'s run loads, worked out as the Rakefile has the library's rake tasks do it.
  def files_for(lowering)
    RubyGBA::Testing::Lowering.files_for(lowering, files: TestSuites.all_files, folders: TestSuites::LOWERING_FOLDERS)
  end

  def keywords_of(method) = method.parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }.sort
end
