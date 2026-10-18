# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# A GAME IN A REPOSITORY OF ITS OWN runs its tests on any lowering, or all of them, with nothing
# but the library and the emulator gem: test/fixtures/game_suite is such a game's Rakefile and
# its test files, and each case here runs its rake from that folder. Its load path is the two
# gems' folders and nothing else (RUBYLIB, so the test processes rake starts have it too, as a
# game's bundle puts them there) — not this repository's test folder and not its bundle, so
# minitest and rake are the plain installed gems and the Ractor test runner this suite uses is
# not there at all.
class TestGameSuite < Minitest::Test
  # Starts child processes, which Ruby cannot do from inside a Ractor — the spawn waits for
  # ever — so on the main Ractor, not in the pool. See test_helper.
  runs_on_the_main_ractor!

  GAME = RubyGBA.root.join("test/fixtures/game_suite").to_s
  LIB = [RubyGBA.root.join("lib"), RubyGBA.root.join("ruby-gba-emulator/lib")].join(File::PATH_SEPARATOR)
  RAKE = Gem.bin_path("rake", "rake")

  # A game that keeps its own rake test and a task for each group of its tests, and its code
  # under a folder of its own, and asks the library for nothing but a native twin of a group.
  GAME_WITH_GROUPS = RubyGBA.root.join("test/fixtures/game_with_groups").to_s

  # The game's rake +tasks+, with nothing of the run this test is in handed down to it. What it
  # printed, whether it passed, which lowerings played the game's tests, and what each test that
  # leaves one left behind ("lowering-test name").
  #
  # Leaving the bundle puts back the settings this process STARTED with, and on a native run
  # that includes the mark a test process of the native run is started with
  # (TEST_PROCESS_CHILD), which it took away as it began. Handed down, the game's own run would
  # take itself for one of those, and wait for tests from a parent it does not have.
  private def rake(*tasks, env: {}, game: GAME)
    Dir.mktmpdir do |played|
      plain = { "RUBYLIB" => LIB, "GAME_SUITE_PLAYED" => played, "RUBY_GBA_LOWERING" => nil,
                "TESTOPTS" => nil, "TEST" => nil, "MT_CPU" => nil, "MT_RACTOR" => nil, "TEST_PROCESSES" => nil,
                "MT_RACTOR_WORKERS" => nil, "TEST_PROCESS_CHILD" => nil }
      out, status = Bundler.with_unbundled_env do
        Open3.capture2e(plain.merge(env), RbConfig.ruby, RAKE, *tasks, chdir: game)
      end
      plays = Dir.children(played).sort
      [out, status.success?, plays.map { |file| file.split("-").first }.uniq.sort, plays]
    end
  end

  def test_rake_test_plays_the_games_tests_on_every_lowering
    out, passed, lowerings = rake("test")

    assert passed, "the game's rake test failed:\n#{out}"
    assert_equal %w[gba gbc js native], lowerings
    assert_match(/^GBA lowering\s+passed/, out)
    assert_match(/^native lowering\s+passed/, out)
    assert_match(/^JavaScript lowering\s+passed/, out)
    assert_match(/^Game Boy Color lowering\s+passed/, out)
  end

  # The native lowering's run alone, its tests played in several processes rather than Ractors.
  def test_one_lowering_plays_the_games_tests_on_that_lowering_alone
    out, passed, lowerings = rake("test:lowering:native")

    assert passed, "the game's native run failed:\n#{out}"
    assert_equal %w[native], lowerings
    assert_match(/Playing 3 tests in \d+ process/, out)
  end

  # An interpreter made to draw one pixel differently fails the game's tests on each run, as
  # failed assertions and not as errors in the library: on the native run the game as C differs
  # from it at a frame, on the JavaScript run the game as JavaScript does, and on the GBA
  # lowering's run the cartridge does, at the pixel named. The walker is laid out for the
  # Advance's screen, so the Game Boy Color's run plays none of it, and says so as a skip.
  def test_a_disagreement_fails_the_games_test_on_each_run
    out, passed, = rake("test", env: { "GAME_SUITE_DISAGREE" => "1" })

    refute passed
    assert_match(/^GBA lowering\s+FAILED/, out)
    assert_match(/^native lowering\s+FAILED/, out)
    assert_match(/^JavaScript lowering\s+FAILED/, out)
    assert_match(/^Game Boy Color lowering\s+passed/, out)
    assert_match(/disagree at frame 1: the picture differs/, out)
    assert_match(/the backends drew different screens: 1 of 38400 pixels differ/, out)
    assert_match(/\(  0,  0\)/, out)
    assert_equal %w[0 0 0 0], out.scan(/(\d+) errors/).flatten, "no run's tests stopped with an error"
  end

  WALKING = "test_holding_right_walks_the_walker"
  MENUS = "test_stands_for_the_rest_of_the_suite"

  # A native twin of one group, under the game's own name for it, over the game's own files and
  # load paths: the group's tests, played as C in several processes, and no others.
  def test_a_native_twin_plays_its_group_as_c
    out, passed, _, plays = rake("test:native:walking", game: GAME_WITH_GROUPS)

    assert passed, "the game's native twin failed:\n#{out}"
    assert_equal ["native-#{WALKING}"], plays
    assert_match(/Playing 1 test in 1 process/, out)
  end

  # A game whose own runs put every test in a Ractor says so in its test options, and its native
  # twin is handed them too. The twin plays without Ractors whatever they say: this game has no
  # Ractor test runner at all, so an option for one that reached its run would stop it.
  def test_a_native_twin_plays_without_ractors_whatever_the_game_asks
    out, passed, _, plays = rake("test:native:walking", game: GAME_WITH_GROUPS,
                                                        env: { "TESTOPTS" => "--ractor", "MT_RACTOR" => "1" })

    assert passed, "the game's native twin failed:\n#{out}"
    assert_equal ["native-#{WALKING}"], plays
  end

  # Asking for the twin leaves the game's own rake test as the game wrote it: one run of every
  # test, on the GBA lowering.
  def test_a_native_twin_leaves_the_games_own_rake_test_alone
    out, passed, _, plays = rake("test", game: GAME_WITH_GROUPS)

    assert passed, "the game's own rake test failed:\n#{out}"
    assert_equal ["gba-#{WALKING}", "gba-#{MENUS}"], plays
    refute_match(/lowering\s+passed/, out)
  end

  # A native twin played before the game's own group in one rake call hands that group nothing
  # of its own: the group still plays as the GBA lowering's run.
  def test_a_native_twin_hands_nothing_to_the_tasks_after_it
    out, passed, _, plays = rake("test:native:walking", "test:walking", game: GAME_WITH_GROUPS)

    assert passed, "the game's rake failed:\n#{out}"
    assert_equal ["gba-#{WALKING}", "native-#{WALKING}"], plays
  end
end
