# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "comparison_games"

# THE SAME SCRIPT ON EACH CARTRIDGE, in place of the same tape on both. Each cartridge is
# played by the script on its own, so each stops walking when ITS box is where the script
# is waiting for it. That forgives timing: it finds a game that looks different, where the
# same tape finds one that is a frame late.
#
# The two cartridges are the walker and a walker twice as quick. The script walks the box
# to the same place on each, which takes the quick one half as many frames.
class TestComparisonSameScript < Minitest::Test
  include ComparisonGames

  private def quick(**changes) = walker(speed: 4, **changes)

  # Stand for ten frames, then walk right until the box is at 60. It starts at 20, so that
  # is twenty frames of walking at the walker's two pixels a frame and ten at four.
  private def walk_to_sixty
    RubyGBA.playthrough "walk to sixty" do
      wait frames: 10
      moment :standing
      hold_until("the box is at sixty", :right) { |game| game.var(:x) >= 60 }
      moment :arrived
    end
  end

  # The frame a cartridge's box gets to 60 on, found the long way round, with no script and
  # no comparison in it: ten frames standing, then RIGHT held a frame at a time and the
  # cartridge asked after each.
  private def arrives_on(cartridge)
    game = RubyGBA::Diagnostics::Verifier.new(cartridge, frames: 0, vars: cartridge.var_addresses)
    game.step(10)
    right = RubyGBA::Diagnostics::Playthrough.key_mask([:right])
    (11..).find { game.step(1, keys: right).var(:x) >= 60 }
  end

  # A CARTRIDGE THAT GETS THERE SOONER HAS NOT DRIFTED ON THE SAME SCRIPT, where it drifts
  # on the same tape: handed the slow one's walk, the quick one is past the place by the
  # time the slow one arrives. And the result says the frame each reached each moment on.
  def test_a_cartridge_that_takes_fewer_frames_has_no_drift_on_the_same_script
    first = walker
    second = quick
    ours, theirs = [first, second].map { |cartridge| arrives_on(cartridge) }

    on_the_tape = walk_to_sixty.compare(first, second)
    on_the_script = walk_to_sixty.compare(first, second, same: :script)

    assert_equal [30, 20], [ours, theirs], "twenty frames of walking at two pixels a frame, ten at four"
    assert_predicate on_the_tape, :drift?
    refute_predicate on_the_script, :drift?
    assert_equal({ standing: [10, 10], arrived: [ours, theirs] }, on_the_script.moments)
    assert_equal ours, on_the_script.frames, "the frames the first cartridge played"
  end

  # The same tape is still what a comparison does with nothing said, and it says the frame
  # of each moment too: the same frame for both, of the moments it reached before it stopped.
  def test_the_same_tape_is_what_it_does_with_nothing_said
    first = walker
    said = walk_to_sixty.compare(first, quick, same: :tape)
    unsaid = walk_to_sixty.compare(first, quick)

    assert_equal said, unsaid
    assert_equal({ standing: [10, 10] }, unsaid.moments, "the two part on the first frame of the walk, before the second moment")
  end

  # A moment that names the very frame a comparison stops on is one it reached, and is said.
  def test_the_same_tape_says_a_moment_that_names_the_frame_it_stopped_on
    first = walker
    second = walker(turns_red_at: 29)
    tape = walk_right.play(first).tape
    turns_on = first_frame(second, tape) { |game| game.red?(0, 0) }

    result = tape.compare(first, second)

    assert_equal [tape.moments.fetch(:walked), result.frames], [turns_on, turns_on], "the ground turns on the frame named :walked"
    assert_equal({ standing: [10, 10], walked: [turns_on, turns_on] }, result.moments)
  end

  # A PICTURE THAT DIFFERS AT A NAMED MOMENT IS DRIFT AT THAT MOMENT. This quick walker's
  # ground turns red after it has stood and before it arrives, so the two are alike at the
  # first moment and not at the second. The drift names the moment, and its frame is the
  # frame the first cartridge reached it on.
  def test_a_picture_that_differs_at_a_moment_is_drift_at_that_moment
    first = walker
    second = quick(turns_red_at: 15)
    arrived_on = arrives_on(first)

    result = walk_to_sixty.compare(first, second, same: :script)

    assert_equal [[:arrived, arrived_on, [:picture]]], result.drifts.map { |drift| [drift.moment, drift.frame, drift.differed] }
    assert_equal [nil, nil], [result.drift.last_frame, result.drift.ended], "a moment is one frame, and has no stretch"
  end

  # It stops at the first moment that differs unless it is asked to carry on, and then
  # every moment that differs is a drift. This ground is red from the start.
  def test_carrying_on_lists_every_moment_that_differs
    first = walker
    second = quick(turns_red_at: 1)

    assert_equal [:standing], walk_to_sixty.compare(first, second, same: :script).drifts.map(&:moment)
    assert_equal %i[standing arrived], walk_to_sixty.compare(first, second, same: :script, carrying_on: true).drifts.map(&:moment)
  end

  # --- how many frames apart ---

  # HOW LONG EACH TOOK IS ONLY DRIFT WHEN A LIMIT IS GIVEN. The quick walker arrives ten
  # frames sooner: with no limit that is said and is not drift, with a limit of ten it is
  # within it, and with a limit of nine it is drift at the moment it arrived, though the
  # two screens there are the same.
  def test_two_cartridges_further_apart_than_the_limit_drift_at_that_moment
    first = walker
    second = quick

    within = walk_to_sixty.compare(first, second, same: :script, frames_apart: 10)
    beyond = walk_to_sixty.compare(first, second, same: :script, frames_apart: 9)
    the_other_way_round = walk_to_sixty.compare(second, first, same: :script, frames_apart: 9)

    assert_equal 10, arrives_on(first) - arrives_on(second)
    refute_predicate walk_to_sixty.compare(first, second, same: :script), :drift?
    refute_predicate within, :drift?
    assert_equal [[:arrived, [:frames_apart]]], beyond.drifts.map { |drift| [drift.moment, drift.differed] }
    assert_equal [[:arrived, [:frames_apart]]], the_other_way_round.drifts.map { |drift| [drift.moment, drift.differed] },
                 "a second cartridge that is later is as far apart as one that is sooner"
  end

  # --- how alike the pictures have to be ---

  # The share of the pixels that may differ is the same question at a moment as on a
  # frame. This second walker has drawn five specks by the moment, and the first none.
  def test_the_share_that_may_differ_holds_at_a_moment
    after_the_specks = RubyGBA.playthrough "wait for the specks" do
      wait frames: 40
      moment :specked
    end
    first = walker
    second = walker(specks: 5)

    assert_predicate after_the_specks.compare(first, second, same: :script), :drift?
    refute_predicate after_the_specks.compare(first, second, same: :script, share_may_differ: 5.0 / PIXELS), :drift?
    assert_predicate after_the_specks.compare(first, second, same: :script, share_may_differ: 4.0 / PIXELS), :drift?
  end

  # --- readings ---

  # A reading is compared at each moment, as each cartridge reaches it. The quick walker
  # has taken half as many paces to arrive, and both are where the script walked them to.
  def test_a_reading_is_compared_at_each_moment
    result = walk_to_sixty.compare(walker, quick, same: :script, readings: { paces: :paces, where: :x })

    assert_equal [[:arrived, [:paces]]], result.drifts.map { |drift| [drift.moment, drift.differed] }
    assert_equal({ paces: [20, 10], where: [60, 60] }, result.drift.readings)
  end

  # --- leaving moments out ---

  # A stretch written in moments leaves out the moments it covers, three dots and an open
  # end meaning what they do in a range.
  def test_a_stretch_of_moments_leaves_those_moments_out
    first = walker
    red_throughout = quick(turns_red_at: 1)
    drifting_at = ->(stretches) { walk_to_sixty.compare(first, red_throughout, same: :script, carrying_on: true, ignoring_frames: stretches).drifts.map(&:moment) }

    assert_equal [:arrived], drifting_at.call([:standing..:standing])
    assert_equal [:arrived], drifting_at.call([:standing...:arrived])
    assert_equal [:arrived], drifting_at.call([(..:standing)])
    assert_equal [:standing], drifting_at.call([(:arrived..)])
  end

  # Leaving out every moment leaves nowhere to compare, the same as naming none, and would
  # find no drift whatever the two did. It is refused before anything is played.
  def test_leaving_out_every_moment_is_refused
    [[:standing..:arrived], [(..:arrived)], [:standing..:standing, (:arrived..)]].each do |all_of_them|
      err = assert_raises(ArgumentError) { walk_to_sixty.compare(nil, nil, same: :script, ignoring_frames: all_of_them) }

      assert_match(/ignoring_frames:/, err.message)
      assert_match(/every moment/, err.message)
    end
  end

  # --- a report of a drift at a moment ---

  # A DRIFT AT A MOMENT GETS A FOLDER NAMED FOR THE MOMENT, with a tape for each cartridge:
  # each made its own presses, and its own tape is the one that plays it back to that
  # moment. The text says the frame each reached it on and what was compared.
  def test_a_drift_at_a_moment_gets_a_folder_with_a_tape_for_each_cartridge
    first = walker
    second = quick(turns_red_at: 15)
    ours, theirs = [first, second].map { |cartridge| arrives_on(cartridge) }

    Dir.mktmpdir("drift") do |somewhere|
      result = walk_to_sixty.compare(first, second, same: :script, frames_apart: 20, readings: { paces: :paces }, reports_in: somewhere)
      folder = result.drift.report
      lines = File.read(File.join(folder, "report.txt")).lines.map(&:strip)
      tapes = %w[first second].map { |side| RubyGBA::Diagnostics::Playthrough::Tape.read(File.join(folder, "#{side}-to-the-moment.tape")) }

      assert_equal File.join(somewhere, "moment-arrived"), folder
      assert_equal %w[difference.png first-to-the-moment.tape first.png report.txt second-to-the-moment.tape second.png], Dir.children(folder).sort
      assert_equal [ours, theirs], tapes.map(&:frames)
      assert_equal [60, 60], [first, second].zip(tapes).map { |cartridge, tape| tape.play(cartridge).game.var(:x) }, "each tape walks its own cartridge there"
      assert_includes lines, "The two cartridges drifted at the moment arrived."
      assert_includes lines, "The first cartridge reached it on frame #{ours} and the second on frame #{theirs}, #{ours - theirs} frames apart."
      assert_includes lines, "What differed at that moment: the picture, the reading paces."
      assert_includes lines, "paces: 20 on the first cartridge, 10 on the second. They differ."
      assert_includes lines, "The two were compared at each named moment, after the same script had played each cartridge by itself."
      assert_includes lines, "A moment differed when one of the pixels was a different colour."
      assert_includes lines, "The limit on how far apart the two reached a moment was 20 frames."
      assert_includes lines, "The presses of the last second on the second cartridge"
    end
  end

  # A report that cannot be written still holds what was found, as on a tape: the drift it
  # could not report and the ones before it. Its words say the moment. The second moment's
  # folder here is blocked by a file of the same name.
  def test_a_report_that_cannot_be_written_still_holds_the_drifts_found_before_it
    Dir.mktmpdir("drift") do |somewhere|
      File.write(File.join(somewhere, "moment-arrived"), "in the way")
      err = assert_raises(RubyGBA::Diagnostics::Comparison::ReportNotWritten) do
        walk_to_sixty.compare(walker, quick(turns_red_at: 1), same: :script, carrying_on: true, reports_in: somewhere)
      end

      assert_equal :arrived, err.drift.moment
      assert_equal [:standing], err.earlier.map(&:moment)
      assert_match(/drifted at the moment arrived/, err.message)
    end
  end

  # Two moments that differ only in their capitals would be one folder on a disk that does
  # not tell them apart, and the second report would be written over the first.
  def test_moments_that_would_share_a_report_folder_are_refused
    two_doors = RubyGBA.playthrough "two doors" do
      wait frames: 5
      moment :Door
      wait frames: 5
      moment :door
    end

    Dir.mktmpdir("drift") do |somewhere|
      err = assert_raises(ArgumentError) { two_doors.compare(nil, nil, same: :script, reports_in: somewhere) }

      assert_match(/:Door and :door/, err.message)
      assert_match(/capital letters/, err.message)
    end
  end

  # --- a script that gives up ---

  # EITHER CARTRIDGE CAN FAIL TO GET WHERE THE SCRIPT IS WAITING FOR IT, and the error says
  # which: a script's own error has no way to know there were two. This wait gives the box
  # thirty frames to get to 60, which the walker makes and a walker half as quick does not.
  def test_a_script_that_gives_up_says_which_cartridge_it_gave_up_on
    impatient = RubyGBA.playthrough "walk to sixty, soon" do
      wait frames: 10
      hold_until("the box is at sixty", :right, within: 30) { |game| game.var(:x) >= 60 }
      moment :arrived
    end

    err = assert_raises(RubyGBA::Diagnostics::Playthrough::GaveUp) { impatient.compare(walker, walker(speed: 1), same: :script) }

    assert_match(/second cartridge/, err.message)
    assert_match(/the box is at sixty/, err.message)
    assert_equal "the box is at sixty", err.words
  end

  # With no limit on how far apart, and a moment left out, the report says both.
  def test_a_report_says_no_limit_was_set_and_which_moments_were_left_out
    Dir.mktmpdir("drift") do |somewhere|
      result = walk_to_sixty.compare(walker, quick(turns_red_at: 1), same: :script, ignoring_frames: [:standing..:standing], reports_in: somewhere)
      lines = File.read(File.join(result.drift.report, "report.txt")).lines.map(&:strip)

      assert_includes lines, "How many frames apart the two reached a moment was not checked."
      assert_includes lines, "These moments were not looked at: standing."
    end
  end

  # --- what makes no sense on the same script, refused before anything is played ---

  # WITH NO NAMED MOMENT THERE IS NOWHERE TO COMPARE, so a script that names none is refused.
  def test_a_script_with_no_moment_cannot_be_compared_on_the_same_script
    no_moments = RubyGBA.playthrough("a walk") { hold :right, frames: 10 }

    err = assert_raises(ArgumentError) { no_moments.compare(nil, nil, same: :script) }

    assert_match(/names no moment/, err.message)
    assert_match(/moment :/, err.message)
  end

  def test_settings_that_count_frames_are_refused_on_the_same_script
    {
      { frames_in_a_row: 2 } => /frames_in_a_row:.*same script/,
      { ignoring_frames: [1..5] } => /ignoring_frames:.*frame numbers/,
      { frames_apart: -1 } => /frames_apart:.*0 or more/,
      { frames_apart: 1.5 } => /frames_apart:.*whole number/,
    }.each do |wrong, says|
      err = assert_raises(ArgumentError) { walk_to_sixty.compare(nil, nil, same: :script, **wrong) }

      assert_match(says, err.message)
    end
  end

  def test_a_way_of_feeding_that_is_not_one_is_refused
    err = assert_raises(ArgumentError) { walk_to_sixty.compare(nil, nil, same: :moments) }

    assert_match(/same:/, err.message)
    assert_match(/:tape.*:script/, err.message)
  end

  # On the same tape the two are always on the same frame, so a limit on how far apart they
  # are means the caller thought it was the same script.
  def test_frames_apart_is_refused_on_the_same_tape
    err = assert_raises(ArgumentError) { walk_to_sixty.compare(nil, nil, frames_apart: 3) }

    assert_match(/frames_apart:/, err.message)
    assert_match(/same: :script/, err.message)
  end

  # A tape is the presses and holds no script, so it cannot play each cartridge by itself.
  # That is said as a tape's own mistake whatever else was given, and of the setting that
  # only a script has too: nothing about a script that is not there.
  def test_a_tape_cannot_be_compared_on_the_same_script
    tape = RubyGBA.playthrough("no moments") { wait frames: 5 }.play(walker).tape

    [{ same: :script }, { same: :script, frames_in_a_row: 2 }, { frames_apart: 3 }].each do |settings|
      err = assert_raises(ArgumentError) { tape.compare(nil, nil, **settings) }

      assert_match(/given to a tape/, err.message)
      assert_match(/no script/, err.message)
      refute_match(/names no moment|give `same: :script` too/, err.message)
    end
  end
end
