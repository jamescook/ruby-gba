# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "comparison_games"

# NAMED READINGS: a comparison can compare numbers read off the two running cartridges as
# well as their pictures. Two games can show the same screen and be a long way apart
# underneath, and a number a pixel out is far easier to chase than a picture that looks wrong.
#
# The two cartridges here are the walker and a walker that counts two paces for each frame it
# walks, where the first counts one. Nothing on the screen shows the count, so the two
# pictures never differ; the count differs from the first frame of the walk.
class TestComparisonReadings < Minitest::Test
  runs_on :reference

  include ComparisonGames

  private def counting_twice = walker(counts_by: 2)

  # The first frame of the walk on a tape, as the walker itself says: the frame its count
  # of paces first leaves nought.
  private def first_pace_on(cartridge, tape) = first_frame(cartridge, tape) { |game| game.var(:paces).positive? }

  # A READING THAT DIFFERS IS DRIFT ON THE FIRST FRAME IT DIFFERS, though the two pictures
  # are the same on every frame. The reading here is a variable's name, which is all a
  # reading needs to be on two cartridges the framework built.
  def test_a_reading_that_differs_is_drift_though_the_pictures_agree
    first = walker
    second = counting_twice
    walks_on = first_pace_on(first, walk_right.play(first).tape)

    refute walk_right.compare(first, second).drift?, "the pictures alone never differ"
    result = walk_right.compare(first, second, readings: { paces: :paces })

    assert_equal walks_on, result.drift.frame
    assert_equal [:paces], result.drift.differed
    assert_equal :standing, result.drift.moment
  end

  # A READING CAN BE READ ITS OWN WAY FROM EACH CARTRIDGE, which is what lets two games that
  # keep the same thing differently be compared at all. The second cartridge here counts
  # two for every pace, so halving its count is how far it has walked — and read that way
  # the two agree on every frame, where the bare counts part at the first pace.
  def test_a_reading_given_one_way_for_each_side_compares_values_kept_differently
    first = walker
    second = counting_twice
    walks_on = first_pace_on(first, walk_right.play(first).tape)

    as_paces = walk_right.compare(first, second, readings: { walked: [:paces, ->(game) { game.var(:paces) / 2 }] })
    as_counted = walk_right.compare(first, second, readings: { walked: %i[paces paces] })

    refute as_paces.drift?, "one pace on the first is two counted on the second"
    assert_equal walks_on, as_counted.drift.frame
  end

  # THE SAME THING KEPT IN TWO DIFFERENT PLACES. The second cartridge here is the same game
  # with two more variables declared ahead of its own, so its count of paces is kept
  # somewhere else in memory. Read from each cartridge's own place, the two agree on every
  # frame; read from the first cartridge's place on both, the second gives back something
  # else it keeps there.
  def test_a_reading_is_read_from_a_different_place_in_each_cartridge
    first = walker
    second = walker(spare_variables: 2)
    ours, theirs = [first, second].map { |cartridge| cartridge.var_addresses.fetch(:paces) }
    at = ->(address) { ->(game) { game.mem32(address) } }

    refute_equal ours, theirs, "the two keep their count in different places"
    refute walk_right.compare(first, second, readings: { paces: [at[ours], at[theirs]] }).drift?
    assert_predicate walk_right.compare(first, second, readings: { paces: at[ours] }), :drift?
  end

  # ONE WAY TO READ, USED FOR BOTH: a block handed each running cartridge in turn. What it
  # gives back can be anything two of which can be the same, a pair of numbers included.
  def test_a_reading_given_one_way_is_read_that_way_from_both
    first = walker
    second = counting_twice
    walks_on = first_pace_on(first, walk_right.play(first).tape)

    where = walk_right.compare(first, second, readings: { where: ->(game) { game.var(:x) } })
    both = walk_right.compare(first, second, readings: { where_and_count: ->(game) { [game.var(:x), game.var(:paces)] } })

    refute where.drift?, "the two walk at the same speed"
    assert_equal walks_on, both.drift.frame
    assert_equal [:where_and_count], both.drift.differed
  end

  # --- choosing what is compared ---

  # WHAT IS COMPARED IS A LIST, and it is the picture and the readings unless said. A
  # comparison told to compare the readings only does not look at the picture: this ground
  # turns red before the walk begins, and the drift is the count parting on the first pace.
  def test_comparing_the_readings_only_does_not_report_the_picture
    first = walker
    second = walker(turns_red_at: 5, counts_by: 2)
    tape = walk_right.play(first).tape
    turns_on = first_frame(second, tape) { |game| game.red?(0, 0) }
    walks_on = first_pace_on(first, tape)

    both = tape.compare(first, second, readings: { paces: :paces })
    readings_only = tape.compare(first, second, readings: { paces: :paces }, comparing: [:readings])

    assert_operator turns_on, :<, walks_on
    assert_equal [turns_on, [:picture]], [both.drift.frame, both.drift.differed]
    assert_equal [walks_on, [:paces]], [readings_only.drift.frame, readings_only.drift.differed]
    refute tape.compare(first, walker(turns_red_at: 5), readings: { paces: :paces }, comparing: [:readings]).drift?,
           "a picture that differs is no drift when only the readings are compared"
  end

  # Told to compare the picture only, a reading that differs is no drift. It is still read:
  # see the drift's readings, below.
  def test_comparing_the_picture_only_does_not_report_a_reading
    refute walk_right.compare(walker, counting_twice, readings: { paces: :paces }, comparing: [:picture]).drift?
  end

  # On the frame both part, both are said, the picture first.
  def test_a_frame_on_which_both_differ_says_both
    first = walker
    second = walker(speed: 3, counts_by: 2)

    result = walk_right.compare(first, second, readings: { paces: :paces, ticks: :ticks })

    assert_equal first_pace_on(first, walk_right.play(first).tape), result.drift.frame
    assert_equal %i[picture paces], result.drift.differed
  end

  def test_a_list_of_what_to_compare_that_makes_no_sense_is_refused
    paces = { paces: :paces }
    {
      { comparing: [] } => /at least one/,
      { comparing: :readings, readings: paces } => /must be a list/,
      { comparing: %i[picture sound] } => /:sound/,
      { comparing: [:readings] } => /no readings/,
      { comparing: %i[picture readings] } => /no readings/,
    }.each do |wrong, says|
      err = assert_raises(ArgumentError) { walk_right.compare(nil, nil, **wrong) }

      assert_match(/comparing:/, err.message)
      assert_match(says, err.message)
    end
  end

  # --- the settings that say which frames count hold for a reading as for the picture ---

  # The reading here is whether the ground is red, read off the screen by a block, with the
  # picture itself not compared. Red for two frames is not drift when three in a row are
  # asked for; red for three is, on the first of them.
  def test_a_reading_has_to_differ_for_as_many_frames_in_a_row_as_were_asked_for
    first = walker
    tape = walk_right.play(first).tape
    ground_is_red = { red: ->(game) { game.red?(0, 0) } }
    three_red = walker(turns_red_at: 45, red_for: 3)
    turns_on = first_frame(three_red, tape) { |game| game.red?(0, 0) }

    briefly = tape.compare(first, walker(turns_red_at: 45, red_for: 2), readings: ground_is_red, comparing: [:readings], frames_in_a_row: 3)
    long_enough = tape.compare(first, three_red, readings: ground_is_red, comparing: [:readings], frames_in_a_row: 3)

    refute briefly.drift?
    assert_equal turns_on, long_enough.drift.frame
    assert_equal({ red: [false, true] }, long_enough.drift.readings)
  end

  # EACH THING COUNTS ITS OWN FRAMES IN A ROW. The ground here is red for one frame, and on
  # the two frames after it a reading differs that agreed while the ground was red. That is
  # three frames running on which something differed and no three on which one thing did,
  # so with three asked for it is not drift. With two asked for it is the reading's, on the
  # frame the reading began to differ, and the picture is not named.
  def test_a_flicker_of_one_thing_followed_by_another_is_not_a_run_of_frames
    first = walker
    second = walker(turns_red_at: 45, red_for: 1)
    tape = walk_right.play(first).tape
    red_on = frames_where(second, tape) { |game| game.red?(0, 0) }
    just_after = { late: [->(_game) { false }, ->(game) { (46..47).cover?(game.var(:ticks)) }] }
    late_on = frames_where(second, tape) { |game| (46..47).cover?(game.var(:ticks)) }

    three = tape.compare(first, second, readings: just_after, frames_in_a_row: 3)
    two = tape.compare(first, second, readings: just_after, frames_in_a_row: 2)

    assert_equal [1, [red_on.first + 1, red_on.first + 2]], [red_on.size, late_on], "one red frame, then two late ones"
    refute three.drift?
    assert_equal [late_on.first, [:late]], [two.drift.frame, two.drift.differed]
    assert_equal({ late: [false, true] }, two.drift.readings)
  end

  # A reading that differs inside a stretch that is not looked at is not counted, and one
  # still differing when the stretch ends is drift on the first frame after it.
  def test_a_reading_is_not_compared_on_frames_that_are_not_looked_at
    first = walker
    second = counting_twice

    refute walk_right.compare(first, second, readings: { paces: :paces }, ignoring_frames: [(:standing..)]).drift?
    assert_equal 31, walk_right.compare(first, second, readings: { paces: :paces }, ignoring_frames: [:standing..:walked]).drift.frame,
                 "the walk is frames 11 to 30, and the counts stay apart after it"
  end

  # --- what a drift says of the readings ---

  # A variable of a cartridge on one frame of a tape, played on its own.
  private def var_on(cartridge, tape, frame, name)
    each_frame_of(cartridge, tape) { |game, played| return game.var(name) if played == frame }
  end

  # A DRIFT SAYS EVERY READING ON BOTH CARTRIDGES on the frame it began: the ones that
  # differed and the ones that did not, each name with the first cartridge's value and the
  # second's.
  def test_a_drift_says_every_reading_on_both_cartridges
    first = walker
    second = counting_twice
    tape = walk_right.play(first).tape
    walks_on = first_pace_on(first, tape)
    where = var_on(first, tape, walks_on, :x)

    drift = tape.compare(first, second, readings: { paces: :paces, where: :x }).drift

    assert_equal 22, where, "one step of two from where it stood"
    assert_equal({ paces: [1, 2], where: [22, 22] }, drift.readings)
    assert_equal [:paces], drift.differed
  end

  # Readings that are given and not compared are still said, which is often the quickest
  # way to see what a difference in the picture comes from. With several frames in a row
  # asked for they are of the frame the drift began, like everything else a drift says.
  def test_readings_that_are_not_compared_are_still_said_of_the_frame_the_drift_began
    first = walker
    second = walker(turns_red_at: 20)
    tape = walk_right.play(first).tape
    turns_on = first_frame(second, tape) { |game| game.red?(0, 0) }

    drift = tape.compare(first, second, readings: { where: :x }, comparing: [:picture], frames_in_a_row: 3).drift

    assert_equal turns_on, drift.frame
    assert_equal [:picture], drift.differed
    assert_equal({ where: [var_on(first, tape, turns_on, :x)] * 2 }, drift.readings)
    refute_equal var_on(first, tape, turns_on, :x), var_on(first, tape, turns_on + 2, :x), "the box walked on while it was made sure"
  end

  # A number that is not a number is the same as itself here, though Ruby says it is equal
  # to nothing: both cartridges divide nought by nought until the walk begins.
  def test_two_readings_that_are_both_not_a_number_are_the_same
    ratio = { ratio: ->(game) { 0.0 / game.var(:paces) } }
    not_a_number_at_first = ratio[:ratio].call(RubyGBA::Playthroughs::Playthrough.power_on(walker).step(1))

    assert_predicate not_a_number_at_first, :nan?
    refute walk_right.compare(walker, walker, readings: ratio).drift?
  end

  # A READING'S BLOCK THAT STOPS WITH AN ERROR IS SAID BY ITS NAME AND ITS CARTRIDGE, which
  # the block's own error has no way to know. It is found on the first frame that is looked
  # at, whether or not readings are compared, and not on the frame of a drift.
  def test_a_reading_that_cannot_be_read_says_which_and_from_which_cartridge
    wrong = { hearts: [:paces, ->(game) { game.var(:hearts) }] }

    [{}, { comparing: [:picture] }].each do |settings|
      err = assert_raises(RubyGBA::Playthroughs::Comparison::ReadingFailed) { walk_right.compare(walker, walker, readings: wrong, **settings) }

      assert_match(/:hearts/, err.message)
      assert_match(/second cartridge/, err.message)
      assert_kind_of ArgumentError, err.cause, "the block's own error is still there to read"
    end
  end

  # A comparison given no readings says none.
  def test_a_drift_with_no_readings_says_none
    drift = walk_right.compare(walker, walker(speed: 3)).drift

    assert_equal [:picture], drift.differed
    assert_empty drift.readings
  end

  # THE REPORT LISTS EVERY READING ON BOTH SIDES, says which differed, and says what was
  # compared: here the readings only, on two cartridges whose pictures differ as well.
  def test_the_report_lists_each_reading_on_both_sides
    first = walker
    second = walker(turns_red_at: 5, counts_by: 2)

    Dir.mktmpdir("drift") do |somewhere|
      result = walk_right.compare(first, second, readings: { paces: :paces, where: :x }, comparing: [:readings], reports_in: somewhere)
      lines = File.read(File.join(result.drift.report, "report.txt")).lines.map(&:strip)

      assert_includes lines, "What differed on that frame: the reading paces."
      assert_includes lines, "paces: 1 on the first cartridge, 2 on the second. They differ."
      assert_includes lines, "where: 22 on both."
      assert_includes lines, "The picture was not compared."
      assert_includes lines, "A frame differed when one of these readings was not the same on the two cartridges: paces, where."
      refute(lines.any? { |line| line.include?("pixels was a different colour") })
    end
  end

  # A DRIFT IN A READING ALONE SAYS THE TWO SCREENS WERE THE SAME, rather than that they
  # differed in no pixels: these two cartridges show the same picture on every frame and
  # count their paces differently.
  def test_the_report_of_a_drift_in_a_reading_alone_says_the_screens_were_the_same
    Dir.mktmpdir("drift") do |somewhere|
      result = walk_right.compare(walker, counting_twice, readings: { paces: :paces }, reports_in: somewhere)
      lines = File.read(File.join(result.drift.report, "report.txt")).lines.map(&:strip)

      assert_equal [:paces], result.drift.differed
      assert_includes lines, "The two screens were the same picture there."
      refute(lines.any? { |line| line.include?("0 pixels") })
    end
  end

  # ...AND WHERE THEY DIFFERED ONLY IN A PART LEFT OUT, IT SAYS THAT, since its two pictures
  # show the whole screens. One of these two draws three specks from tick 30 and the other
  # does not; the specks are left out, and a reading says which of them has drawn them.
  def test_the_report_of_a_drift_in_a_reading_alone_says_where_the_screens_differed_unseen
    specks_drawn = { specked: [->(game) { game.var(:ticks) >= SPECKS_FROM }, ->(_game) { false }] }

    Dir.mktmpdir("drift") do |somewhere|
      result = walk_right.compare(walker(specks: 3), walker, readings: specks_drawn,
                                                             ignoring_rectangles: [[SPECK_X, SPECK_Y, 3, 1]], reports_in: somewhere)
      lines = File.read(File.join(result.drift.report, "report.txt")).lines.map(&:strip)

      assert_equal [:specked], result.drift.differed
      assert_includes lines, "The two screens differed only in the parts that were not looked at."
      refute_includes lines, "The two screens were the same picture there."
    end
  end

  # With the picture compared as well, and a reading that is only read, the report says so.
  def test_the_report_says_the_picture_differed_and_that_the_readings_were_only_read
    Dir.mktmpdir("drift") do |somewhere|
      result = walk_right.compare(walker, walker(speed: 3), readings: { where: :x }, comparing: [:picture], reports_in: somewhere)
      lines = File.read(File.join(result.drift.report, "report.txt")).lines.map(&:strip)

      assert_includes lines, "What differed on that frame: the picture."
      assert_includes lines, "where: 22 on the first cartridge, 23 on the second. They differ."
      assert_includes lines, "A frame differed when one of the pixels was a different colour."
      assert_includes lines, "The readings were read and were not compared."
    end
  end

  # --- a cartridge the framework did not build ---

  # A VARIABLE'S NAME MEANS NOTHING ON A CARTRIDGE THAT WAS NOT BUILT HERE: which variable is
  # where is kept beside a cartridge and never in it, and a file has only what is in it. So
  # it is refused before a frame is played, saying which reading, which cartridge and what
  # to give in its place. Given a block for that side, the same reading is compared.
  def test_a_variable_name_is_refused_on_a_cartridge_that_was_not_built_here
    first = walker
    second = counting_twice
    Dir.mktmpdir("cartridges") do |folder|
      as_a_file = File.join(folder, "twice.gba").tap { |path| second.write(path) }
      count_kept_at = second.var_addresses.fetch(:paces)

      err = assert_raises(ArgumentError) { walk_right.compare(first, as_a_file, readings: { paces: :paces }) }
      by_address = walk_right.compare(first, as_a_file, readings: { paces: [:paces, ->(game) { game.mem32(count_kept_at) }] })

      assert_match(/:paces/, err.message)
      assert_match(/second cartridge/, err.message)
      assert_match(/not built here/, err.message)
      assert_match(/address/, err.message)
      assert_equal first_pace_on(first, walk_right.play(first).tape), by_address.drift.frame
    end
  end

  # It is the first cartridge a script is played on to make its tape, and a name that
  # cartridge cannot answer is refused before that playing and not after it.
  def test_a_variable_name_on_a_first_cartridge_not_built_here_is_refused_before_it_is_played
    played = false
    watching = RubyGBA.playthrough "watch" do
      wait_until("a frame has gone by") { |_game| played = true }
    end
    Dir.mktmpdir("cartridges") do |folder|
      as_a_file = File.join(folder, "walker.gba").tap { |path| walker.write(path) }

      err = assert_raises(ArgumentError) { watching.compare(as_a_file, walker, readings: { paces: :paces }) }

      refute played
      assert_match(/first cartridge/, err.message)
      assert_match(/not built here/, err.message)
    end
  end

  # A name the cartridge has no variable of is a slip of spelling, and is refused before a
  # frame is played too, naming the variables it does have and none of the framework's own.
  def test_a_variable_the_cartridge_does_not_have_is_refused_naming_the_ones_it_has
    played = false
    watching = RubyGBA.playthrough "watch" do
      wait_until("a frame has gone by") { |_game| played = true }
    end

    err = assert_raises(ArgumentError) { watching.compare(walker, counting_twice, readings: { count: %i[paces pace] }) }

    refute played, "it is refused before the script is played on the first cartridge"
    assert_match(/:count/, err.message)
    assert_match(/:pace from the second cartridge/, err.message)
    %i[ticks x paces].each { |own| assert_includes err.message, own.inspect }
    refute_match(/__frames|_dma_scratch/, err.message)
  end

  # --- readings that are not written as readings, refused before a cartridge is looked at ---

  def test_readings_written_wrongly_are_refused
    a_way = ->(game) { game.var(:x) }
    {
      [:paces] => /names, each with a way/,
      { paces: 3 } => /:paces as 3/,
      { paces: [:paces] } => /:paces as \[:paces\]/,
      { paces: [:paces, a_way, a_way] } => /not a way to read it/,
      { paces: [:paces, "x"] } => /not a way to read it/,
      { "paces" => :paces } => /must be a symbol/,
      { picture: :paces } => /means the picture of the screen/,
    }.each do |wrong, says|
      err = assert_raises(ArgumentError) { walk_right.compare(nil, nil, readings: wrong) }

      assert_match(/readings:/, err.message)
      assert_match(says, err.message)
    end
  end
end
