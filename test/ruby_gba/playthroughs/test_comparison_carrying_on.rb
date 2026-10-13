# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "comparison_games"
require "png_reading"

# CARRYING ON PAST THE FIRST DRIFT. A comparison stops at the first drift unless it is asked
# to carry on, and then it plays to the end and lists every stretch of drift: the frame it
# began on and the last frame the two still differed. That answers what the first drift
# cannot: do the two come back into step, or is everything after it different for one reason?
#
# The cartridges are the walker and a walker whose ground is red for a few frames, found by
# playing that walker on its own.
class TestComparisonCarryingOn < Minitest::Test
  include ComparisonGames
  include PNGReading

  BLUE = [0, 0, 255].freeze
  RED = [255, 0, 0].freeze

  private def red_frames(cartridge, tape) = frames_where(cartridge, tape) { |game| game.red?(0, 0) }

  # TWO CARTRIDGES THAT DIFFER FOR A WHILE AND THEN AGREE AGAIN ARE ONE STRETCH, from the
  # first frame they differed to the last, and the comparison plays to the end of the tape.
  def test_a_stretch_of_differing_frames_is_one_drift_with_its_first_and_last_frame
    first = walker
    second = walker(turns_red_at: 45, red_for: 3)
    tape = walk_right.play(first).tape
    red_on = red_frames(second, tape)

    result = tape.compare(first, second, carrying_on: true)

    assert_equal 3, red_on.size
    assert_equal tape.frames, result.frames, "it played to the end"
    assert_equal [[red_on.first, red_on.last]], result.drifts.map { |drift| [drift.frame, drift.last_frame] }
    assert_equal result.drifts.first, result.drift, "the first drift is still the one asked for by itself"
  end

  # TWO STRETCHES ARE TWO DRIFTS, in the order they happened, each saying what differed in
  # it. The first here is a reading that is out for three frames during the walk, and the
  # second the ground turning red for three frames after it.
  def test_two_stretches_are_two_drifts
    first = walker
    second = walker(turns_red_at: 45, red_for: 3)
    tape = walk_right.play(first).tape
    red_on = red_frames(second, tape)
    out_for_a_while = { late: [->(_game) { false }, ->(game) { (20..22).cover?(game.var(:ticks)) }] }
    late_on = frames_where(second, tape) { |game| (20..22).cover?(game.var(:ticks)) }

    result = tape.compare(first, second, readings: out_for_a_while, carrying_on: true)

    assert_operator late_on.last, :<, red_on.first
    assert_equal [late_on.first..late_on.last, red_on.first..red_on.last], result.drifts.map(&:stretch)
    assert_equal [[:late], [:picture]], result.drifts.map(&:differed)
    assert_equal %i[standing walked], result.drifts.map(&:moment)
  end

  # A DRIFT THAT NEVER ENDS RUNS TO THE LAST FRAME PLAYED: the ground turns red and stays red.
  def test_a_drift_that_never_ends_runs_to_the_last_frame_played
    first = walker
    second = walker(turns_red_at: 45)
    tape = walk_right.play(first).tape

    result = tape.compare(first, second, carrying_on: true)

    assert_equal [red_frames(second, tape).first..tape.frames], result.drifts.map(&:stretch)
    assert_equal tape.frames, result.frames
  end

  # WITH NOTHING SAID IT STOPS AT THE FIRST DRIFT, as it always did: one drift, and no frame
  # played after the one that made it certain. How long that drift lasted is then not
  # known, and it says so by having no last frame.
  def test_with_nothing_said_a_comparison_stops_at_the_first_drift
    first = walker
    second = walker(turns_red_at: 45, red_for: 3)
    tape = walk_right.play(first).tape
    red_on = red_frames(second, tape)

    [{}, { carrying_on: false }].each do |settings|
      result = tape.compare(first, second, **settings)

      assert_equal red_on.first, result.frames
      assert_equal [red_on.first], result.drifts.map(&:frame)
      assert_equal [nil, nil, nil], [result.drift.last_frame, result.drift.ended, result.drift.stretch]
    end
  end

  # HOW A DRIFT ENDED IS SAID WITH IT, which is the question carrying on is for. The two
  # came back into step; or the next frame was one the comparison was told to leave out, so
  # nothing is known; or the tape ran out with the two still apart.
  def test_a_drift_says_how_it_ended
    first = walker
    tape = walk_right.play(first).tape
    for_a_while = walker(turns_red_at: 45, red_for: 3)
    red_on = red_frames(for_a_while, tape)
    ended = ->(second, **settings) { tape.compare(first, second, carrying_on: true, **settings).drifts.map(&:ended) }

    assert_equal [:back_in_step], ended.call(for_a_while)
    assert_equal [:not_looked_at], ended.call(for_a_while, ignoring_frames: [(red_on[1]..)])
    assert_equal [:tape_ran_out], ended.call(walker(turns_red_at: 45))
    assert_predicate tape.compare(first, for_a_while, carrying_on: true).drift, :back_in_step?
    refute_predicate tape.compare(first, walker(turns_red_at: 45), carrying_on: true).drift, :back_in_step?
  end

  # Two cartridges that never differ have no drift to list, carrying on or not.
  def test_no_drift_is_an_empty_list
    result = walk_right.compare(walker, walker, carrying_on: true)

    assert_empty result.drifts
    assert_nil result.drift
    refute_predicate result, :drift?
  end

  # --- with the other settings ---

  # A stretch has to be as long as was asked for to be listed at all: three red frames are
  # a drift when three in a row are asked for, and not when four are.
  def test_a_stretch_shorter_than_was_asked_for_is_not_listed
    first = walker
    second = walker(turns_red_at: 45, red_for: 3)
    tape = walk_right.play(first).tape
    red_on = red_frames(second, tape)

    assert_equal [red_on.first..red_on.last], tape.compare(first, second, carrying_on: true, frames_in_a_row: 3).drifts.map(&:stretch)
    assert_empty tape.compare(first, second, carrying_on: true, frames_in_a_row: 4).drifts
  end

  # A frame that is not looked at ends a drift, since nothing is known about it, and a
  # difference still there after it is a drift of its own. Five red frames with the middle
  # one left out are two drifts of two frames.
  def test_a_frame_that_is_not_looked_at_splits_a_drift_in_two
    first = walker
    second = walker(turns_red_at: 45, red_for: 5)
    tape = walk_right.play(first).tape
    red_on = red_frames(second, tape)
    middle = red_on[2]

    result = tape.compare(first, second, carrying_on: true, ignoring_frames: [middle..middle])

    assert_equal 5, red_on.size
    assert_equal [red_on[0]..red_on[1], red_on[3]..red_on[4]], result.drifts.map(&:stretch)
  end

  # WITH SEVERAL FRAMES IN A ROW ASKED FOR, A DRIFT LASTS WHILE SOMETHING THAT HAS DIFFERED
  # FOR THAT LONG GOES ON DIFFERING. A reading that is out for one frame straight after the
  # red frames has not, so it does not carry the drift on a frame further; with one frame
  # asked for, every differing frame counts and the two run together as one drift.
  def test_a_flicker_straight_after_a_drift_does_not_carry_it_on
    first = walker
    second = walker(turns_red_at: 45, red_for: 3)
    tape = walk_right.play(first).tape
    red_on = red_frames(second, tape)
    one_frame_after = { late: [->(_game) { false }, ->(game) { game.var(:ticks) == 48 }] }
    late_on = frames_where(second, tape) { |game| game.var(:ticks) == 48 }

    strict = tape.compare(first, second, readings: one_frame_after, carrying_on: true)
    forgiving = tape.compare(first, second, readings: one_frame_after, carrying_on: true, frames_in_a_row: 3)

    assert_equal [red_on.last + 1], late_on, "the reading is out on the frame after the last red one"
    assert_equal [red_on.first..late_on.first], strict.drifts.map(&:stretch)
    assert_equal [%i[picture late]], strict.drifts.map(&:differed), "a drift names everything that differed while it lasted"
    assert_equal [red_on.first..red_on.last], forgiving.drifts.map(&:stretch)
    assert_equal [[:picture]], forgiving.drifts.map(&:differed)
  end

  # NO FRAME IS IN TWO DRIFTS. The ground is red for three frames and a reading is out for
  # three, the first of them the last red frame, with three in a row asked for. On the
  # frame the ground goes back the reading has been out for two frames, which is not yet
  # drift; a frame later it is. That is one drift of five frames, and not a second one
  # that began inside the first.
  def test_a_thing_that_goes_on_past_the_end_of_another_is_the_same_drift
    first = walker
    second = walker(turns_red_at: 45, red_for: 3)
    tape = walk_right.play(first).tape
    red_on = red_frames(second, tape)
    overlapping = { late: [->(_game) { false }, ->(game) { (47..49).cover?(game.var(:ticks)) }] }
    late_on = frames_where(second, tape) { |game| (47..49).cover?(game.var(:ticks)) }

    result = tape.compare(first, second, readings: overlapping, carrying_on: true, frames_in_a_row: 3)

    assert_equal [red_on.last, red_on.last + 2], [late_on.first, late_on.last], "the reading begins on the last red frame"
    assert_equal [red_on.first..late_on.last], result.drifts.map(&:stretch)
    assert_equal [%i[picture late]], result.drifts.map(&:differed)
  end

  # The same overlap with a reading that is out for two frames only, which never counts:
  # the drift ends where the ground went back, and is not carried on by it.
  def test_a_thing_that_overlaps_a_drift_and_never_counts_does_not_carry_it_on
    first = walker
    second = walker(turns_red_at: 45, red_for: 3)
    tape = walk_right.play(first).tape
    red_on = red_frames(second, tape)
    briefly = { late: [->(_game) { false }, ->(game) { (47..48).cover?(game.var(:ticks)) }] }

    result = tape.compare(first, second, readings: briefly, carrying_on: true, frames_in_a_row: 3)

    assert_equal [red_on.first..red_on.last], result.drifts.map(&:stretch)
    assert_equal [[:picture]], result.drifts.map(&:differed)
    assert_equal [:back_in_step], result.drifts.map(&:ended)
  end

  # One frame alike in the middle of a difference ends the drift, and what follows is a
  # drift of its own once it has lasted as long as was asked for. The reading here is out
  # for two frames, right for one, and out for two more, with two in a row asked for.
  def test_one_frame_alike_in_the_middle_ends_a_drift_and_the_rest_is_another
    first = walker
    tape = walk_right.play(first).tape
    out_on_ticks = [40, 41, 43, 44]
    out_twice = { late: [->(_game) { false }, ->(game) { out_on_ticks.include?(game.var(:ticks)) }] }
    out_on = frames_where(first, tape) { |game| out_on_ticks.include?(game.var(:ticks)) }

    result = tape.compare(first, walker, readings: out_twice, carrying_on: true, frames_in_a_row: 2)

    assert_equal [out_on[0]..out_on[1], out_on[2]..out_on[3]], result.drifts.map(&:stretch)
    assert_equal out_on[1] + 2, out_on[2], "one frame between the two on which the reading was right"
  end

  # --- a report of each ---

  # EACH DRIFT GETS A FOLDER OF ITS OWN, named for the frame it began on, holding that
  # drift and no other, and each drift says which folder is its own. The two drifts here
  # are a reading that is out during the walk, when both grounds are blue, and the ground
  # turning red after it — so the two folders hold different pictures and different words.
  def test_each_drift_gets_a_report_folder_of_its_own
    first = walker
    second = walker(turns_red_at: 45, red_for: 3)
    tape = walk_right.play(first).tape
    red_on = red_frames(second, tape)
    out_for_a_while = { late: [->(_game) { false }, ->(game) { (20..22).cover?(game.var(:ticks)) }] }
    late_on = frames_where(second, tape) { |game| (20..22).cover?(game.var(:ticks)) }

    Dir.mktmpdir("drift") do |somewhere|
      result = tape.compare(first, second, readings: out_for_a_while, carrying_on: true, reports_in: somewhere)
      of_the_reading, of_the_ground = result.drifts.map(&:report)

      assert_equal ["frame-0000#{late_on.first}", "frame-0000#{red_on.first}"], Dir.children(somewhere).sort
      assert_equal Dir.children(somewhere).sort, [of_the_reading, of_the_ground].map { |folder| File.basename(folder) }
      result.drifts.each do |drift|
        assert_equal %w[difference.png first.png report.txt second.png to-the-drift.tape], Dir.children(drift.report).sort
        assert_equal drift.frame, RubyGBA::Playthroughs::Tape.read(File.join(drift.report, "to-the-drift.tape")).frames
      end
      assert_equal [BLUE, RED], [of_the_reading, of_the_ground].map { |folder| png_pixels(File.binread(File.join(folder, "second.png"))).first }
      assert_includes report_lines(of_the_reading), "What differed on that frame: the reading late."
      assert_includes report_lines(of_the_reading), "The drift lasted to frame #{late_on.last}. The two were back within the settings on frame #{late_on.last + 1}."
      assert_includes report_lines(of_the_ground), "What differed on that frame: the picture."
      assert_includes report_lines(of_the_ground), "The drift lasted to frame #{red_on.last}. The two were back within the settings on frame #{red_on.last + 1}."
    end
  end

  private def report_lines(folder) = File.read(File.join(folder, "report.txt")).lines.map(&:strip)

  # A report says how its drift ended in each of the ways one can: back in step, cut off by
  # a frame that was not looked at, still going at the end of the tape, or not known
  # because the comparison stopped there.
  def test_a_report_says_how_long_the_drift_lasted
    first = walker
    tape = walk_right.play(first).tape
    for_a_while = walker(turns_red_at: 45, red_for: 3)
    red_on = red_frames(for_a_while, tape)
    report_of = lambda do |second, **settings|
      Dir.mktmpdir("drift") { |somewhere| report_lines(tape.compare(first, second, reports_in: somewhere, **settings).drift.report) }
    end

    assert_includes report_of.call(for_a_while, carrying_on: true, ignoring_frames: [(red_on[1]..)]),
                    "The drift lasted to frame #{red_on[0]}. Frame #{red_on[1]} was not looked at."
    assert_includes report_of.call(walker(turns_red_at: 45), carrying_on: true), "The drift lasted to frame #{tape.frames}, the last frame of the tape."
    assert_includes report_of.call(for_a_while), "The comparison stopped at this drift, so how long it lasted is not known."
  end

  # A report that cannot be written stops the comparison, and what it had found is not lost
  # with it: the error holds the drift it could not report and the ones before it. The
  # second drift's folder here is blocked by a file of the same name.
  def test_a_report_that_cannot_be_written_still_holds_the_drifts_found_before_it
    first = walker
    second = walker(turns_red_at: 45, red_for: 3)
    tape = walk_right.play(first).tape
    red_on = red_frames(second, tape)
    out_for_a_while = { late: [->(_game) { false }, ->(game) { (20..22).cover?(game.var(:ticks)) }] }
    late_on = frames_where(second, tape) { |game| (20..22).cover?(game.var(:ticks)) }

    Dir.mktmpdir("drift") do |somewhere|
      File.write(File.join(somewhere, "frame-0000#{red_on.first}"), "in the way")
      err = assert_raises(RubyGBA::Playthroughs::Comparison::ReportNotWritten) do
        tape.compare(first, second, readings: out_for_a_while, carrying_on: true, reports_in: somewhere)
      end

      assert_equal red_on.first, err.drift.frame
      assert_equal [late_on.first..late_on.last], err.earlier.map(&:stretch)
      assert_equal [File.join(somewhere, "frame-0000#{late_on.first}")], err.earlier.map(&:report)
    end
  end

  # --- a setting that is not yes or no ---

  def test_carrying_on_has_to_be_true_or_false
    ["yes", 1, nil, :first].each do |wrong|
      err = assert_raises(ArgumentError) { walk_right.compare(nil, nil, carrying_on: wrong) }

      assert_match(/carrying_on:/, err.message)
      assert_match(/true or false/, err.message)
    end
  end
end
