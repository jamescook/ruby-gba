# frozen_string_literal: true

require "test_helper"
require "stringio"
require_relative "../tools/cost_accuracy"

# The corpus accuracy check (tools/cost_accuracy.rb): how close the estimate is to the
# console, on every example rather than on whichever one somebody last looked at.
#
# The verdict is pure — it compares a recorded list of readings against a fresh one — so
# these run without building a ROM or starting an emulator. What they pin is the JUDGEMENT:
# which movements are a failure, which are not, and what the run says about the corpus as a
# whole. Taking the readings is the tool's other half and is exercised by `rake cost:check`.
class TestCostAccuracy < Minitest::Test
  Reading = CostAccuracy::Reading
  Verdict = CostAccuracy::Baseline::Verdict

  def reading(name, estimate:, measured:)
    Reading.new(name: name, estimate: estimate, measured: measured)
  end

  def recorded(rows)
    CostAccuracy::Baseline.rows(rows).transform_keys(&:to_s)
  end

  def verdict(was, now)
    Verdict.new(recorded: recorded(was), measured: now)
  end

  def render(verdict)
    io = StringIO.new
    verdict.render(io)
    io.string
  end

  # THE FAILURE THIS EXISTS FOR: a change that helps one example and hurts the rest. Tuned
  # against one game that reading looks like progress; across the corpus it is a regression
  # with seven names on it.
  def test_it_fails_when_an_example_drifts_further_from_the_console
    was = [reading("pong", estimate: 58.0, measured: 60.0)]
    now = [reading("pong", estimate: 30.0, measured: 60.0)] # estimate halved: 1.03x becomes 2.0x

    v = verdict(was, now)

    refute_predicate v, :ok?
    assert_includes v.drifted.keys, "pong"
    assert_match(/drifted further from the console/, render(v))
    assert_match(/rake cost:record/, render(v), "and says how to accept it when it was meant")
  end

  # Wrong in the other direction is the same failure. An estimate that grew too dear is not
  # safer than one too cheap — it sends a reader optimising something that is already fine.
  def test_drifting_too_dear_fails_the_same_way
    was = [reading("maze", estimate: 8.0, measured: 8.0)]
    now = [reading("maze", estimate: 24.0, measured: 8.0)]

    refute_predicate verdict(was, now), :ok?
  end

  def test_getting_closer_is_never_a_failure
    was = [reading("lake", estimate: 0.3, measured: 7.4)]
    now = [reading("lake", estimate: 7.0, measured: 7.4)]

    v = verdict(was, now)

    assert_predicate v, :ok?
    assert_includes v.improved, "lake"
    assert_match(/Closer than recorded/, render(v))
  end

  # The console does not read the same twice to a fraction of a scanline, so a hair of
  # movement is not drift. Without this the check would cry wolf on every run and be turned
  # off, which is worse than not having it.
  def test_a_hair_of_movement_is_not_drift
    was = [reading("snake", estimate: 64.6, measured: 57.7)]
    now = [reading("snake", estimate: 64.6, measured: 57.6)]

    assert_predicate verdict(was, now), :ok?
  end

  # An example with no game loop has no per-frame cost, so there is nothing to be right or
  # wrong about. It is recorded, and it is not scored.
  def test_a_program_with_no_frame_is_not_scored
    now = [Reading.new(name: "tiles", note: "no game loop, so nothing recurs")]

    v = verdict([], now)

    assert_predicate v, :ok?
    assert_match(/No example could be scored/, render(v))
  end

  # ...but one that USED to be scorable and is not any more is a real regression, and a
  # quiet one: it would otherwise leave the corpus a name at a time.
  def test_losing_a_reading_that_used_to_work_is_a_failure
    was = [reading("shmup", estimate: 4.2, measured: 5.3)]
    now = [Reading.new(name: "shmup", note: "over a frame, and the pass was not counted")]

    v = verdict(was, now)

    refute_predicate v, :ok?
    assert_includes v.broken.keys, "shmup"
  end

  # The line worth reading on a green run: whether the model is getting better across the
  # board, and which examples are furthest off. A count with no names would say the corpus
  # is bad without saying where to look.
  def test_a_green_run_says_how_the_whole_corpus_stands
    now = [reading("pong", estimate: 58.0, measured: 60.0),
           reading("lake", estimate: 0.3, measured: 7.4)]

    text = render(verdict(now, now))

    assert_match(/within a tenth of the console on 1 of 2 examples/, text)
    assert_match(/Furthest off: lake/, text)
  end

  # A ratio is only as good as knowing which way it points, so the reading carries the
  # direction and the distance apart: 0.5x and 2.0x are equally wrong.
  def test_being_half_and_being_double_are_equally_far_off
    half = reading("a", estimate: 20.0, measured: 10.0)
    double = reading("b", estimate: 10.0, measured: 20.0)

    assert_in_delta 2.0, half.distance, 0.001
    assert_in_delta 2.0, double.distance, 0.001
    assert_in_delta 0.5, half.ratio, 0.001
  end
end
