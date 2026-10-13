# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "comparison_games"

# A LEAD-IN: a script of its own played on a cartridge before the playthrough starts. A
# cartridge somebody else made shows logos and an introduction that another does not, so two
# cartridges from power-on are out of step before the first press. A lead-in for each gets
# each to where the playthrough should begin, and nothing in it is counted: its frames are
# not on the tape, and frame 1 is the first frame after it.
#
# The cartridges are the walker, and a walker that shows a black screen for some frames
# before its game begins.
class TestPlaythroughLeadIn < Minitest::Test
  runs_on :reference

  include ComparisonGames

  Tape = RubyGBA::Playthroughs::Tape

  # A PLAYTHROUGH AFTER A LEAD-IN COUNTS ITS FRAMES FROM THE END OF THE LEAD-IN, and its tape
  # holds its own presses and none of the lead-in's. So a walker with a logo, led in past
  # it, plays the walk exactly as a walker with none: the same frames, the same moments,
  # the box in the same place, and the same lines on the tape.
  def test_a_playthrough_after_a_lead_in_counts_from_the_end_of_it
    plain = walk_right.play(walker, lead_in: past_the_logo)
    after_a_logo = walk_right.play(walker(logo_for: 7), lead_in: past_the_logo)

    assert_equal 60, after_a_logo.frames, "ten standing, twenty walking, thirty more, and no frame of the lead-in"
    assert_equal({ standing: 10, walked: 30 }, after_a_logo.moments)
    assert_equal [plain.game.var(:x), plain.game.var(:ticks)], [after_a_logo.game.var(:x), after_a_logo.game.var(:ticks)]
    assert_equal ["10 -", "moment standing", "20 right", "moment walked", "30 -"], after_a_logo.tape.to_s.lines.drop(4).map(&:chomp)
    assert after_a_logo.pictures.fetch(:walked) == plain.pictures.fetch(:walked), "the two are in step, picture for picture"
  end

  # --- a tape recorded after a lead-in ---

  # A TAPE SAYS IT WAS RECORDED AFTER A LEAD-IN and holds none of its presses, so it is
  # played after one or not at all: with no lead-in the same presses start somewhere else.
  # Written to a file and read back, it still says so.
  def test_a_tape_recorded_after_a_lead_in_says_so_and_is_played_after_one
    cartridge = walker(logo_for: 7)
    played = walk_right.play(cartridge, lead_in: past_the_logo)
    tape = Tape.parse(played.tape.to_s)

    err = assert_raises(ArgumentError) { tape.play(cartridge) }
    again = tape.play(cartridge, lead_in: past_the_logo)

    assert_equal "starts from: power-on after a lead-in", played.tape.to_s.lines[2].chomp
    assert_equal played.tape, tape
    assert_match(/lead-in/, err.message)
    assert_match(/lead_in:/, err.message)
    assert_equal played.game.var(:x), again.game.var(:x)
    assert_equal "starts from: power-on", walk_right.play(walker).tape.to_s.lines[2].chomp, "and a tape with none says nothing of one"
  end

  # --- two cartridges, a lead-in each ---

  # The frames a walker's lead-in takes, found the long way: frames stepped by hand until
  # its ground is blue.
  private def lead_in_frames(cartridge)
    game = RubyGBA::Diagnostics::Verifier.new(cartridge, frames: 0)
    (1..).find { game.step(1).blue?(0, 0) }
  end

  # TWO CARTRIDGES THAT DIFFER ONLY IN HOW LONG THEY TAKE TO REACH THEIR FIRST SCREEN DRIFT
  # FROM POWER-ON, and have no drift once each has a lead-in that waits for that screen —
  # fed the same tape, or each played by the same script.
  def test_two_cartridges_out_of_step_from_power_on_are_in_step_after_a_lead_in_each
    first = walker
    second = walker(logo_for: 7)
    lead_ins = [past_the_logo, past_the_logo]

    in_step = walk_right.compare(first, second, lead_ins: lead_ins)

    assert_equal 7, lead_in_frames(second) - lead_in_frames(first), "the logo is all that is between them"
    assert_predicate walk_right.compare(first, second), :drift?
    refute_predicate in_step, :drift?
    assert_equal 60, in_step.frames, "the frames of the walk, and none of either lead-in"
    refute_predicate walk_right.compare(first, second, lead_ins: lead_ins, same: :script), :drift?
  end

  # FRAMES ARE COUNTED FROM THE FIRST FRAME AFTER THE LEAD-INS. This second walker's ground
  # turns red: from power-on, with no logo, that is on a frame found by playing it alone,
  # and after a lead-in it is that many frames sooner as the lead-in is long.
  def test_a_drift_after_lead_ins_is_counted_from_the_end_of_them
    first = walker
    turns_on = first_frame(walker(turns_red_at: 45), walk_right.play(first).tape) { |game| game.red?(0, 0) }

    result = walk_right.compare(first, walker(logo_for: 7, turns_red_at: 45), lead_ins: [past_the_logo, past_the_logo])

    assert_equal turns_on - lead_in_frames(first), result.drift.frame
    assert_equal :walked, result.drift.moment
  end

  # One cartridge can have a lead-in and the other none. This second walker's ground turns
  # red on a frame found by playing it alone; led in by five frames with the first led in
  # by none, it is five frames further on, and turns five frames sooner. (Frame 1 is left
  # out: from power-on it is the blank before a game's first picture, which the walker that
  # was led in is already past.)
  def test_a_lead_in_can_be_given_to_one_cartridge_only
    first = walker
    second = walker(turns_red_at: 45)
    turns_on = first_frame(second, walk_right.play(first).tape) { |game| game.red?(0, 0) }
    five_frames = RubyGBA.playthrough("five frames") { wait frames: 5 }

    assert_equal turns_on, walk_right.compare(first, second, ignoring_frames: [1..1]).drift.frame
    assert_equal turns_on - 5, walk_right.compare(first, second, ignoring_frames: [1..1], lead_ins: [nil, five_frames]).drift.frame
  end

  # The report of a drift says each cartridge was led in, and its tape that it starts after
  # a lead-in: played with one, it is on the drifting frame again.
  def test_a_report_after_lead_ins_says_so_and_its_tape_needs_one
    first = walker
    second = walker(logo_for: 7, turns_red_at: 45)

    Dir.mktmpdir("drift") do |somewhere|
      result = walk_right.compare(first, second, lead_ins: [past_the_logo, past_the_logo], reports_in: somewhere)
      tape = Tape.read(File.join(result.drift.report, "to-the-drift.tape"))
      lines = File.read(File.join(result.drift.report, "report.txt")).lines.map(&:strip)

      assert_predicate tape, :recorded_after_lead_in?
      assert_equal result.drift.frame, tape.frames
      assert tape.play(second, lead_in: past_the_logo).game.red?(0, 0), "led in and played, the second is on its red frame"
      assert_includes lines, "Each cartridge was led in before frame 1, by these playthroughs: past the logo, past the logo."
    end
  end

  # WHERE THE TWO WERE STARTED DIFFERENTLY THERE IS A TAPE FOR EACH, the same presses under
  # two headings: a tape says where it starts, and a cartridge that was led in is not
  # started as one that was not. Each plays its own cartridge to the drifting frame.
  def test_cartridges_started_differently_get_a_tape_each
    first = walker
    second = walker(turns_red_at: 45)
    five_frames = RubyGBA.playthrough("five frames") { wait frames: 5 }

    Dir.mktmpdir("drift") do |somewhere|
      result = walk_right.compare(first, second, ignoring_frames: [1..1], lead_ins: [nil, five_frames], reports_in: somewhere)
      folder = result.drift.report
      ours, theirs = %w[first second].map { |side| Tape.read(File.join(folder, "#{side}-to-the-drift.tape")) }
      lines = File.read(File.join(folder, "report.txt")).lines.map(&:strip)

      assert_equal %w[difference.png first-to-the-drift.tape first.png report.txt second-to-the-drift.tape second.png side-by-side.png],
                   Dir.children(folder).sort
      assert_equal [false, true], [ours, theirs].map(&:recorded_after_lead_in?)
      assert_equal ours.steps, theirs.steps
      refute ours.play(first).game.red?(0, 0)
      assert theirs.play(second, lead_in: five_frames).game.red?(0, 0), "led in and played, the second is on its red frame"
      assert_includes lines, "The second cartridge was led in before frame 1, by the playthrough five frames."
    end
  end

  # A tape that knows nothing of how a comparison started is written down saying it: this
  # one was recorded from power-on, and the report's says it starts after a lead-in.
  def test_a_report_tape_says_how_the_comparison_started_whatever_the_tape_said
    first = walker
    second = walker(logo_for: 7, turns_red_at: 45)
    from_power_on = walk_right.play(first).tape

    Dir.mktmpdir("drift") do |somewhere|
      result = from_power_on.compare(first, second, lead_ins: [past_the_logo, past_the_logo], reports_in: somewhere)

      refute_predicate from_power_on, :recorded_after_lead_in?
      assert_predicate Tape.read(File.join(result.drift.report, "to-the-drift.tape")), :recorded_after_lead_in?
    end
  end

  # A tape recorded after a lead-in is compared with a lead-in too: with none, or with none
  # for either cartridge, both would start somewhere the presses were not made for.
  def test_a_tape_recorded_after_a_lead_in_is_compared_with_lead_ins
    first = walker
    second = walker(logo_for: 7)
    tape = walk_right.play(first, lead_in: past_the_logo).tape

    [{}, { lead_ins: [nil, nil] }].each do |settings|
      err = assert_raises(ArgumentError) { tape.compare(first, second, **settings) }

      assert_match(/after a lead-in/, err.message)
      assert_match(/lead_ins:/, err.message)
    end
    refute_predicate tape.compare(first, second, lead_ins: [past_the_logo, past_the_logo]), :drift?
  end

  # A lead-in that never gets where it is going gives up as any wait does, saying it was
  # the lead-in's and which of the two cartridges it was on. This one waits for a red
  # ground, which the second walker never has.
  def test_a_lead_in_that_gives_up_says_which_cartridge_it_was_on
    until_red = RubyGBA.playthrough "until the ground is red" do
      wait_until("the ground is red", within: 5) { |game| game.red?(0, 0) }
    end

    err = assert_raises(RubyGBA::Playthroughs::GaveUp) do
      walk_right.compare(walker, walker, lead_ins: [nil, until_red])
    end

    assert_match(/second cartridge/, err.message)
    assert_match(/until the ground is red/, err.message)
  end

  # --- what is not a lead-in ---

  def test_a_lead_in_that_is_not_a_playthrough_is_refused
    err = assert_raises(ArgumentError) { walk_right.play(nil, lead_in: "past the logo") }

    assert_match(/lead-in/, err.message)
    assert_match(/playthrough/, err.message)
  end

  def test_lead_ins_that_are_not_one_for_each_cartridge_are_refused
    [past_the_logo, [past_the_logo], [past_the_logo, "x"], [nil, nil, nil]].each do |wrong|
      err = assert_raises(ArgumentError) { walk_right.compare(nil, nil, lead_ins: wrong) }

      assert_match(/lead_ins:/, err.message)
      assert_match(/one for each cartridge/, err.message)
    end
  end
end
