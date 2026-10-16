# frozen_string_literal: true

require "test_helper"

# `rake test` plays the suite once for each lowering: the GBA lowering's run (the interpreter,
# with the cartridge checked in the emulator) and the native lowering's (the game built as C,
# checked against the interpreter). Every test is played by both, except a test of one
# lowering's own output, which lives in a folder that lowering owns. Its other side is
# test_native_suite.rb, in the native lowering's folder, which fails if the GBA run ever plays it.
class TestSuitesSplit < Minitest::Test
  PLAYERS = [Reference, CheckedNativeRun, RubyGBA::IR::Backends::Native::CheckedRun,
             RubyGBA::IR::Backends::Native::HeadlessRun].freeze

  # A test of one lowering's own output — the ARM a cartridge is made of, the cartridge played in
  # the emulator, the C the native lowering writes — lives in a folder that lowering owns, and
  # the other lowering's run never loads it. Every other file is loaded by both.
  def test_a_lowering_run_leaves_out_the_other_lowerings_folders
    native_run = TestSuites.files(lowering: :native)
    interpreter_run = TestSuites.files(lowering: :reference)

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
    if TestSuites.native?
      assert_raises(Minitest::Skip) { skip_on_native "only says something on a native run" }
    else
      skip_on_native "only says something on a native run"
      pass
    end
  end

  private

  def keywords_of(method) = method.parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }.sort
end
