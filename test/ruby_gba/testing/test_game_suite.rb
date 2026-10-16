# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# A GAME IN A REPOSITORY OF ITS OWN runs its tests on either lowering, or both, with nothing
# but the library: test/fixtures/game_suite is such a game's Rakefile and one test file, and
# each case here runs its rake from that folder. Its load path is the library and nothing else
# (RUBYLIB, so the test processes rake starts have it too) — not this repository's test folder
# and not its bundle, so minitest and rake are the plain installed gems and the Ractor test
# runner this suite uses is not there at all.
class TestGameSuite < Minitest::Test
  # Starts child processes, which Ruby cannot do from inside a Ractor — the spawn waits for
  # ever — so on the main Ractor, not in the pool. See test_helper.
  runs_on_the_main_ractor!

  GAME = RubyGBA.root.join("test/fixtures/game_suite").to_s
  LIB = RubyGBA.root.join("lib").to_s
  RAKE = Gem.bin_path("rake", "rake")

  # The game's rake +task+, with nothing of the run this test is in handed down to it. What it
  # printed, whether it passed, and which lowerings played the game's tests.
  #
  # Leaving the bundle puts back the settings this process STARTED with, and on a native run
  # that includes the mark a test process of the native run is started with
  # (TEST_PROCESS_CHILD), which it took away as it began. Handed down, the game's own run would
  # take itself for one of those, and wait for tests from a parent it does not have.
  private def rake(task, env = {})
    Dir.mktmpdir do |played|
      plain = { "RUBYLIB" => LIB, "GAME_SUITE_PLAYED" => played, "RUBY_GBA_LOWERING" => nil,
                "TESTOPTS" => nil, "TEST" => nil, "MT_CPU" => nil, "MT_RACTOR" => nil, "TEST_PROCESSES" => nil,
                "MT_RACTOR_WORKERS" => nil, "TEST_PROCESS_CHILD" => nil }
      out, status = Bundler.with_unbundled_env do
        Open3.capture2e(plain.merge(env), RbConfig.ruby, RAKE, task, chdir: GAME)
      end
      lowerings = Dir.children(played).map { |file| file.split("-").first }.uniq.sort
      [out, status.success?, lowerings]
    end
  end

  def test_rake_test_plays_the_games_tests_on_every_lowering
    out, passed, lowerings = rake("test")

    assert passed, "the game's rake test failed:\n#{out}"
    assert_equal %w[gba native], lowerings
    assert_match(/^GBA lowering\s+passed/, out)
    assert_match(/^native lowering\s+passed/, out)
  end

  # The native lowering's run alone, its tests played in several processes rather than Ractors.
  def test_one_lowering_plays_the_games_tests_on_that_lowering_alone
    out, passed, lowerings = rake("test:lowering:native")

    assert passed, "the game's native run failed:\n#{out}"
    assert_equal %w[native], lowerings
    assert_match(/Playing 2 tests in \d+ process/, out)
  end

  # A game the C plays differently from the interpreter fails a test on the native run, as a
  # failed assertion naming the frame, not as an error in the library.
  def test_a_disagreement_fails_the_games_test_on_the_native_run
    out, passed, = rake("test", "GAME_SUITE_DISAGREE" => "1")

    refute passed
    assert_match(/^GBA lowering\s+passed/, out)
    assert_match(/^native lowering\s+FAILED/, out)
    assert_match(/1 failures, 0 errors/, out)
    assert_match(/disagree at frame 1: the picture differs/, out)
  end
end
