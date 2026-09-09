# frozen_string_literal: true

require_relative "test_helper"

# Tests for the profiler — where a ROM's frames actually went.
#
# These assert the behavioral contract rather than exact addresses, which move
# whenever the lowering changes. The one that carries the most weight is
# test_a_loop_body_is_counted_once_per_pass: a loop written to run exactly N
# times shows its body counted N times, which can only come out right if the
# sampling really is per instruction AND the program counter has had the
# processor's read-ahead taken back off it. Get either wrong and that number is
# not near N.
class TestGembaCoreProfile < Minitest::Test
  include GembaCoreTestSupport

  # A loop that does a known, countable amount of work each frame.
  def adding_rom(passes, name, code)
    build_rom(name, code: code) do
      screen :bitmap
      clear_screen :black
      var :x, 0
      game_loop { repeat(passes) { add :x, 1 } }
    end
  end

  def idle_rom
    build_rom("PIDL", code: "PIDL") do
      screen :bitmap
      clear_screen :black
      game_loop {}
    end
  end

  # Work that only happens while LEFT is held — a game costs what the player
  # makes it cost, so a profile has to be able to hold buttons.
  def held_rom
    build_rom("PHLD", code: "PHLD") do
      screen :bitmap
      clear_screen :black
      var :x, 0
      game_loop { held(:left).then { repeat(500) { add :x, 1 } } }
    end
  end

  def test_a_loop_body_is_counted_once_per_pass
    with_probe(adding_rom(500, "P500", "P500")) do |probe|
      profile = probe.profile(settle: 10)
      _address, seen = profile.hottest(1).first

      assert_in_delta 500, seen, 5,
                      "a loop written to run 500 times shows its body about 500 times"
    end
  end

  def test_twice_the_work_is_twice_the_instructions
    small = with_probe(adding_rom(500, "P50B", "P50B")) { |p| p.profile(settle: 10).samples }
    large = with_probe(adding_rom(1000, "P1KB", "P1KB")) { |p| p.profile(settle: 10).samples }

    assert_in_delta 2.0, large.to_f / small, 0.1, "doubling the loop doubles the instructions"
  end

  def test_an_idle_loop_runs_almost_nothing
    idle = with_probe(idle_rom) { |p| p.profile(settle: 10).samples }
    busy = with_probe(adding_rom(500, "P50C", "P50C")) { |p| p.profile(settle: 10).samples }

    assert_operator idle, :<, busy / 10, "a loop that does nothing costs a fraction of one that works"
  end

  def test_every_instruction_lands_somewhere_it_can_be_counted
    with_probe(adding_rom(500, "P50D", "P50D")) do |probe|
      profile = probe.profile(settle: 10)

      assert_equal 0, profile.elsewhere,
                   "a normal game runs from memory the profile has room to count"
      assert_operator profile.samples, :>, 0
    end
  end

  # THE CHECK THAT CATCHES A WRONG PROGRAM COUNTER, and the only one here that
  # can. This chip reads ahead, so the register never holds the address that is
  # running and a fixed amount has to come off it. Get that amount wrong and
  # every address moves by the same four bytes — so every count stays exactly
  # where it was and every other test in this file still passes, while the report
  # quietly blames the instruction before the one doing the work.
  #
  # A cartridge begins with a branch at 0x08000000, so profiled from a cold boot
  # that address must come up, and take one word too many off and it is reported
  # at 0x07FFFFFC, which is not a place code runs from — so it lands in
  # +elsewhere+ instead. Both halves are asserted.
  def test_the_first_instruction_of_the_cartridge_is_where_the_cartridge_starts
    with_probe(adding_rom(500, "PENT", "PENT")) do |probe|
      profile = probe.profile(frames: 1) # a cold boot: nothing settled

      assert_equal 1, profile.pc[0x0800_0000],
                   "a cartridge starts with a branch at 0x08000000, run once on the way in"
      assert_equal 0, profile.elsewhere,
                   "nothing ran outside a region that can be counted"
    end
  end

  def test_the_sleep_at_the_end_of_a_frame_is_counted_apart
    with_probe(idle_rom) do |probe|
      profile = probe.profile(settle: 10)

      assert_operator profile.halted, :>, 0,
                      "a game that finishes its work sleeps until the screen comes round"
      assert_operator profile.idle_share, :>, 0.9,
                      "a game loop that does nothing is asleep nearly all of every frame"
    end
  end

  # The sleep is measured in cycles rather than steps because the emulator
  # answers a sleep by jumping straight to the next thing due — so it is one
  # step whether the game slept for a scanline or for the whole frame.
  def test_a_busier_game_sleeps_less
    idle = with_probe(idle_rom) { |p| p.profile(settle: 10).idle_share }
    busy = with_probe(adding_rom(1000, "PBSY", "PBSY")) { |p| p.profile(settle: 10).idle_share }

    assert_operator busy, :<, idle, "a game doing real work has less of its frame left over"
  end

  def test_code_addresses_are_whole_instructions
    with_probe(adding_rom(500, "P50E", "P50E")) do |probe|
      ragged = probe.profile(settle: 10).pc.keys.reject { |address| (address % 4).zero? }

      assert_empty ragged, "this program is built of four-byte instructions, so every address is one"
    end
  end

  def test_profiling_holds_the_buttons_it_is_given
    path = held_rom
    still = with_probe(path) { |p| p.profile(settle: 10).samples }
    walking = with_probe(path) { |p| p.profile(settle: 10, keys: :left).samples }

    assert_operator walking, :>, still * 5, "with LEFT down the game does its work and the profile sees it"
  end

  def test_more_frames_profiled_means_proportionally_more_instructions
    path = adding_rom(500, "P50F", "P50F")
    one = with_probe(path) { |p| p.profile(settle: 10, frames: 1) }
    four = with_probe(path) { |p| p.profile(settle: 10, frames: 4) }

    assert_equal 4, four.frames
    assert_in_delta 4.0, four.samples.to_f / one.samples, 0.2, "four frames cost four frames"
    assert_in_delta one.samples, four.samples_per_frame, one.samples * 0.1,
                    "per frame, the two agree"
  end

  def test_hottest_is_ordered_and_share_of_adds_up
    with_probe(adding_rom(500, "P50G", "P50G")) do |probe|
      profile = probe.profile(settle: 10)
      counts = profile.hottest(5).map(&:last)

      assert_equal counts.sort.reverse, counts, "hottest is dearest first"
      assert_in_delta 1.0, profile.share_of(profile.pc.keys), 0.0001,
                      "every address together is the whole run"
      assert_in_delta 0.0, profile.share_of([]), 0.0001, "no addresses is none of it"
    end
  end

  # The framework keeps the code a frame spends its time in in the console's
  # quick memory, which is a different place in the address map from the
  # cartridge. That the profile shows the hot code THERE is the check that it is
  # reading real addresses rather than plausible ones.
  def test_the_hot_code_is_where_the_build_put_it
    with_probe(adding_rom(500, "P50H", "P50H")) do |probe|
      address, = probe.profile(settle: 10).hottest(1).first

      assert_equal 0x0300_0000, address & 0xFF00_0000,
                   "the frame's own body was kept in the console's quick memory"
    end
  end

  def test_frames_must_be_positive
    with_probe(idle_rom) do |probe|
      assert_raises(ArgumentError) { probe.profile(frames: 0) }
    end
  end
end
