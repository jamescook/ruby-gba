# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "cli_playing"

# `ruby-gba compare`: two cartridges played side by side from the command line. It says
# whether they drift and where, and ends in a way another program can act on: 0 when they
# agree, 1 when they drift, 2 when they could not be compared. Every setting a comparison
# takes from Ruby is the flag of the same name.
#
# The cartridges are built from one game file with a setting changed: the quick one walks
# four pixels a frame where the game walks two, and the red one turns its ground red on its
# forty-fifth tick, after the walk. Each is there as a cartridge file and as a game file,
# since only a game file has variables with names.
class TestCommandLineCompare < Minitest::Test
  include CLIPlaying

  AGREED = 0
  DRIFTED = 1
  NOT_COMPARED = 2

  private def with_cartridges
    with_game_and_scripts do |dir|
      cli("build", "walker.rb", "-o", "walker.gba", dir: dir)
      cli("build", "walker.rb", "--set", "red_at=45", "-o", "red.gba", dir: dir)
      File.write(File.join(dir, "quick.rb"), GAME.sub("setting :speed, 2", "setting :speed, 4"))
      File.write(File.join(dir, "red.rb"), GAME.sub("setting :red_at, 100_000", "setting :red_at, 45"))
      yield dir
    end
  end

  # TWO CARTRIDGES THAT AGREE: it says so, and ends with 0. One is the game file and the
  # other the cartridge file built from it.
  def test_two_cartridges_that_agree_end_with_nought
    with_cartridges do |dir|
      out, status = cli("compare", "walker.rb", "walker.gba", "--script", "walk.rb", dir: dir)

      assert_equal AGREED, status.exitstatus, out
      assert_match(/The two cartridges agree\. 60 frames were played, and no frame drifted\./, out)
    end
  end

  # TWO THAT DRIFT: it says the frame, the moment before it and where the report is, and
  # ends with 1. The ground turns on the forty-fifth trip round the game's loop, which is
  # that many frames in and the frame or two the console spends setting up. The report is
  # the folder for that frame, and the tape in it is that many frames long.
  def test_two_cartridges_that_drift_end_with_one_and_say_where
    with_cartridges do |dir|
      out, status = cli("compare", "walker.gba", "red.gba", "--script", "walk.rb", "--reports-in", "drift", dir: dir)
      frame = out[/drifted on frame (\d+)\./, 1].to_i
      report = File.join("drift", format("frame-%06d", frame))
      tape = File.readlines(File.join(dir, report, "to-the-drift.tape"), chomp: true).drop(4)

      assert_equal DRIFTED, status.exitstatus, out
      assert_includes 45..47, frame, out
      assert_match(/The moment named before it was walked\./, out)
      assert_match(/what differed: picture$/, out)
      assert_includes out, "report: #{report}"
      assert_equal frame, tape.grep(/\A\d/).sum(&:to_i), "the tape in the report plays to that frame"
    end
  end

  # --- every setting, said on the command line ---

  # Each of these turns the drift above into none, the way it does from Ruby: every pixel
  # may differ; the red has to last longer than the tape does; the whole screen is left
  # out, in one rectangle and in two; the frames from the walk's end on are left out, by
  # number and by a moment.
  def test_each_setting_that_forgives_a_drift_forgives_it
    with_cartridges do |dir|
      [
        %w[--share-may-differ 1],
        %w[--frames-in-a-row 100],
        %w[--ignoring-rectangles 0,0,240,160],
        %w[--ignoring-rectangles 0,0,240,80 0,80,240,80],
        %w[--ignoring-frames 31..],
        %w[--ignoring-frames walked..],
      ].each do |forgiving|
        out, status = cli("compare", "walker.gba", "red.gba", "--script", "walk.rb", *forgiving, dir: dir)

        assert_equal AGREED, status.exitstatus, "#{forgiving.join(' ')}: #{out}"
        assert_match(/agree/, out)
      end
    end
  end

  # The same settings, said so that they do not reach the drift, leave it: half the pixels
  # may differ where nearly all do; the top half of the screen is left out where the whole
  # ground turned; the frames left out end before the turn.
  def test_a_setting_that_does_not_reach_the_drift_leaves_it
    with_cartridges do |dir|
      [
        %w[--share-may-differ 0.5],
        %w[--ignoring-rectangles 0,0,240,80],
        %w[--ignoring-frames 1..5],
        %w[--ignoring-frames ..walked],
      ].each do |short|
        out, status = cli("compare", "walker.gba", "red.gba", "--script", "walk.rb", *short, dir: dir)

        assert_equal DRIFTED, status.exitstatus, "#{short.join(' ')}: #{out}"
      end
    end
  end

  # --carrying-on plays to the end and says how long the drift lasted: here to the last frame.
  def test_carrying_on_says_how_long_the_drift_lasted
    with_cartridges do |dir|
      out, status = cli("compare", "walker.gba", "red.gba", "--script", "walk.rb", "--carrying-on", dir: dir)

      assert_equal DRIFTED, status.exitstatus, out
      assert_match(/it lasted to frame 60 \(the last frame that was played\)/, out)
    end
  end

  # --readings names variables. A reading that reads a different variable from each is a
  # drift, and is what differed; one that reads the same variable from both, by its own
  # name or under another, is none.
  def test_readings_name_variables_to_compare
    with_cartridges do |dir|
      itself = ["compare", "walker.rb", "walker.rb", "--script", "walk.rb", "--readings"]

      by_reading, differed = cli(*itself, "where=x,ticks", dir: dir)
      same_variable, agreed = cli(*itself, "x", "where=x", dir: dir)

      assert_equal DRIFTED, differed.exitstatus, by_reading
      assert_match(/what differed: where$/, by_reading)
      assert_equal AGREED, agreed.exitstatus, same_variable
    end
  end

  # --comparing says what is compared. The red game's picture drifts from the game's and
  # its box is in the same place, so with only the readings compared the two agree, and
  # with the picture compared too they do not.
  def test_comparing_says_what_is_compared
    with_cartridges do |dir|
      with_a_reading = ["compare", "walker.rb", "red.rb", "--script", "walk.rb", "--readings", "x"]

      readings_only, agreed = cli(*with_a_reading, "--comparing", "readings", dir: dir)
      both, drifted = cli(*with_a_reading, dir: dir)

      assert_equal AGREED, agreed.exitstatus, readings_only
      assert_equal DRIFTED, drifted.exitstatus, both
      assert_match(/what differed: picture$/, both)
    end
  end

  # --same script plays the script on each by itself: the quick walker gets to sixty ten
  # frames sooner and that is not drift, unless --frames-apart says how far apart is too
  # far. (Both are game files here: the script watches a variable by its name, which a
  # cartridge file has none of.)
  def test_same_script_and_frames_apart
    with_cartridges do |dir|
      on_the_script = ["compare", "walker.rb", "quick.rb", "--script", "several.rb", "--playthrough", "walk to sixty", "--same", "script"]

      forgiven, agreed = cli(*on_the_script, dir: dir)
      too_far, failed = cli(*on_the_script, "--frames-apart", "9", dir: dir)
      on_the_tape, drifted = cli(*on_the_script[0..-3], dir: dir)

      assert_equal AGREED, agreed.exitstatus, forgiven
      assert_match(/agree at every named moment/, forgiven)
      assert_match(/arrived +first 30, second 20$/, forgiven)
      assert_equal DRIFTED, failed.exitstatus, too_far
      assert_match(/drifted at the moment arrived: frame 30 on the first, frame 20 on the second\./, too_far)
      assert_match(/what differed: frames_apart$/, too_far)
      assert_equal DRIFTED, drifted.exitstatus, on_the_tape
    end
  end

  # --set reaches a game file: the game file built to walk four pixels a frame drifts from
  # the cartridge file that walks two, which is already built and takes no setting.
  def test_set_reaches_a_game_file
    with_cartridges do |dir|
      out, status = cli("compare", "walker.rb", "walker.gba", "--script", "walk.rb", "--set", "speed=4", dir: dir)

      assert_equal DRIFTED, status.exitstatus, out
    end
  end

  # --save starts both from one save, and --lead-ins plays a lead-in on each first. Each is
  # shown by a tape that needs it: one recorded from a save is refused without --save, and
  # one recorded after a lead-in without --lead-ins. Both refusals name the flag.
  def test_save_and_lead_ins
    with_cartridges do |dir|
      cli("play", "walker.rb", "--script", "walk.rb", "--write-save", "walked.sav", dir: dir)
      cli("play", "walker.rb", "--script", "walk.rb", "--save", "walked.sav", "--write-tape", "from-a-save.tape", dir: dir)
      cli("play", "walker.rb", "--script", "several.rb", "--playthrough", "stand", "--lead-in", "five frames",
          "--write-tape", "led-in.tape", dir: dir)
      from_a_save = ["compare", "walker.rb", "walker.gba", "--tape", "from-a-save.tape"]
      led_in = ["compare", "walker.rb", "walker.gba", "--tape", "led-in.tape"]

      refused, without = cli(*from_a_save, dir: dir)
      agreed, with = cli(*from_a_save, "--save", "walked.sav", dir: dir)
      not_a_save, with_a_script = cli(*from_a_save, "--save", "walk.rb", dir: dir)

      assert_equal NOT_COMPARED, without.exitstatus, refused
      assert_match(/recorded from a save.*--save/, refused)
      assert_equal AGREED, with.exitstatus, agreed
      assert_equal NOT_COMPARED, with_a_script.exitstatus, "the save is handed to the cartridges: #{not_a_save}"

      refused, without = cli(*led_in, dir: dir)
      no_script, without_a_script = cli(*led_in, "--lead-ins", "five frames", "five frames", dir: dir)
      agreed, with = cli(*led_in, "--script", "several.rb", "--lead-ins", "five frames", "five frames", dir: dir)
      one_sided, differently = cli(*led_in, "--script", "several.rb", "--lead-ins", "five frames", "-", dir: dir)

      assert_equal NOT_COMPARED, without.exitstatus, refused
      assert_match(/recorded after a lead-in.*--lead-ins.*--script/, refused)
      assert_equal NOT_COMPARED, without_a_script.exitstatus, no_script
      assert_match(/no script file was given.*--script/, no_script)
      assert_equal AGREED, with.exitstatus, agreed
      assert_equal DRIFTED, differently.exitstatus, "one led in and one not are five frames apart: #{one_sided}"
    end
  end

  # --- what is written wrongly ---

  # Each ends with 2, which is not what a drift ends with, and says what was wrong in the
  # words of the command line: the flag, and not the Ruby setting behind it.
  def test_settings_written_wrongly_end_with_two_and_are_said_plainly
    with_cartridges do |dir|
      {
        %w[--ignoring-rectangles 0,0,240] => /not a rectangle.*X,Y,WIDTH,HEIGHT/,
        %w[--ignoring-rectangles 0,0,300,160] => /--ignoring-rectangles/,
        %w[--ignoring-frames forty] => /not a range/,
        %w[--ignoring-frames 1..walked] => /not a range/,
        %w[--ignoring-frames nowhere..] => /--ignoring-frames/,
        %w[--readings hero=a,b,c] => /not a reading/,
        %w[--readings nobody] => /no variable of that name/,
        %w[--same moments] => /--same.*tape, script/,
        %w[--comparing sound] => /--comparing.*picture, readings/,
        %w[--frames-apart 3] => /--frames-apart/,
        %w[--frames-in-a-row many] => /--frames-in-a-row/,
        %w[--lead-ins nobody -] => /no playthrough named "nobody"/,
        ["--lead-ins", "five frames"] => /--lead-ins needs two names/,
        %w[--tape walk.rb] => /tape/,
      }.each do |wrong, says|
        out, status = cli("compare", "walker.rb", "walker.gba", "--script", "walk.rb", *wrong, dir: dir)

        assert_equal NOT_COMPARED, status.exitstatus, "#{wrong.join(' ')}: #{out}"
        assert_match(says, out)
        refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
      end
    end
  end

  # What cannot be compared at all ends with 2 as well: a cartridge that is not there, a
  # cartridge left out, and a reading of a cartridge file, which has no variable names.
  def test_what_cannot_be_compared_ends_with_two
    with_cartridges do |dir|
      {
        %w[walker.gba nope.gba --script walk.rb] => /cannot find nope\.gba/,
        %w[walker.gba --script walk.rb] => /compare/,
        %w[walker.gba walker.gba --script walk.rb --readings x] => /was not built here/,
        %w[walker.gba red.gba] => /--script.*--tape/,
      }.each do |args, says|
        out, status = cli("compare", *args, dir: dir)

        assert_equal NOT_COMPARED, status.exitstatus, "#{args.join(' ')}: #{out}"
        assert_match(says, out)
        refute_match(/\.rb:\d+:in/, out, "should not leak a backtrace")
      end
    end
  end

  # A GAME FILE FOR TWO CONSOLES is asked which cartridge to compare, and ends with 2 until
  # --console says; then it is compared like any other. Only the Advance's is offered, since a
  # comparison lines screens up at the Advance's size.
  def test_a_game_file_for_two_consoles_is_compared_on_the_console_said
    with_cartridges do |dir|
      File.write(File.join(dir, "both.rb"), GAME.sub("consoles: %i[gba]", "consoles: %i[gba gbc]"))

      asked, asked_status = cli("compare", "both.rb", "walker.gba", "--script", "walk.rb", dir: dir)
      out, status = cli("compare", "both.rb", "walker.gba", "--console", "gba", "--script", "walk.rb", dir: dir)

      assert_equal NOT_COMPARED, asked_status.exitstatus, asked
      assert_match(/WALKER is for the Game Boy Advance and the Game Boy Color/, asked)
      assert_match(/add --console gba\.$/, asked)
      assert_equal AGREED, status.exitstatus, out
    end
  end

  # THE BUILT-IN HELP describes the command, and has a flag of the same name for every
  # setting a comparison takes: a setting added to the library with no flag fails here.
  def test_help_has_a_flag_for_every_setting_of_a_comparison
    with_game_and_scripts do |dir|
      list, = cli("help", dir: dir)
      help, = cli("help", "compare", dir: dir)

      assert_match(/compare FIRST SECOND/, list)
      %w[--script --playthrough --tape --set].each { |option| assert_includes help, option }
      RubyGBA::Playthroughs::Comparison.settings.each { |setting| assert_includes help, "--#{setting.to_s.tr('_', '-')}" }
    end
  end
end
