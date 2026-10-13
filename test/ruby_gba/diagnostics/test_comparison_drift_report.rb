# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "comparison_games"
require "png_reading"

# A DRIFT REPORT: the folder a comparison writes for a drift, when it is given a place to
# write one. It holds what somebody needs to see what went wrong and to get back to it: the
# two screens at the drifting frame, a picture marking where they differ, a few plain
# sentences about it, and a tape that plays either cartridge to that exact frame.
#
# The two cartridges are the walker and a walker whose ground turns red part way through,
# after the box has walked. What each showed on the drifting frame is found by playing it on
# its own to that frame.
class TestComparisonDriftReport < Minitest::Test
  include ComparisonGames
  include PNGReading

  WHITE = [255, 255, 255].freeze
  BLUE = [0, 0, 255].freeze
  RED = [255, 0, 0].freeze
  MARKED = [255, 0, 255].freeze

  private def plain = walker
  private def turning = walker(turns_red_at: 45)

  # The frame the turning cartridge's ground is first red, playing the walk on its own.
  private def turned_on(cartridge, tape) = first_frame(cartridge, tape) { |game| game.red?(0, 0) }

  # A comparison that finds a drift and has somewhere to write, handed the result and the
  # folder it was given.
  private def with_report(first, second, **settings)
    Dir.mktmpdir("drift") do |somewhere|
      reports = File.join(somewhere, "reports")
      yield walk_right.compare(first, second, reports_in: reports, **settings), reports
    end
  end

  # A COMPARISON THAT FINDS A DRIFT WRITES ONE FOLDER FOR IT, named for the frame, and says
  # where: the two pictures, the difference picture, the text file and the tape.
  def test_a_drift_gets_a_folder_holding_its_pictures_its_words_and_its_tape
    first = plain
    second = turning
    on = turned_on(second, walk_right.play(first).tape)

    with_report(first, second) do |result, reports|
      assert_equal on, result.drift.frame
      assert_operator on, :<, 100, "so its number is two digits, and the folder's name pads it to six"
      assert_equal File.join(reports, "frame-0000#{on}"), result.drift.report
      assert_equal [File.basename(result.drift.report)], Dir.children(reports)
      assert_equal %w[difference.png first.png report.txt second.png to-the-drift.tape], Dir.children(result.drift.report).sort
    end
  end

  # The screen a cartridge shows on one frame of a tape, played on its own.
  private def screen_on(cartridge, tape, frame)
    each_frame_of(cartridge, tape) { |game, played| return game.frame_gba if played == frame }
  end

  # A walker's screen as a PNG holds it. It shows three colours and no others.
  private def png_colours_of(screen)
    as_png = { Color.resolve(:white) => WHITE, Color.resolve(:blue) => BLUE, Color.resolve(:red) => RED }
    screen.map { |colour| as_png.fetch(colour) }
  end

  private def png_in(folder, name) = png_pixels(File.binread(File.join(folder, name)))

  # THE TWO PICTURES ARE THE TWO SCREENS ON THE DRIFTING FRAME, and the difference picture
  # marks exactly the pixels that differ between them: here every pixel of the ground, and
  # none of the box, which is white on both.
  def test_the_pictures_are_the_two_screens_and_the_difference_marks_what_differs
    first = plain
    second = turning
    tape = walk_right.play(first).tape
    on = turned_on(second, tape)
    screens = [first, second].map { |cartridge| screen_on(cartridge, tape, on) }
    differing = (0...PIXELS).reject { |at| screens[0][at] == screens[1][at] }

    with_report(first, second) do |result, _reports|
      difference = png_in(result.drift.report, "difference.png")

      assert png_in(result.drift.report, "first.png") == png_colours_of(screens[0]), "first.png is the first cartridge's screen"
      assert png_in(result.drift.report, "second.png") == png_colours_of(screens[1]), "second.png is the second's"
      assert_equal PIXELS - 64, differing.size, "everything but the box, which is eight pixels square"
      assert_equal differing, (0...PIXELS).select { |at| difference[at] == MARKED }
    end
  end

  # THE TAPE IN THE FOLDER PLAYS EITHER CARTRIDGE TO THE DRIFTING FRAME, where it shows the
  # picture of it that is in the folder.
  def test_the_tape_plays_either_cartridge_to_the_drifting_frame
    first = plain
    second = turning

    with_report(first, second) do |result, _reports|
      tape = RubyGBA::Diagnostics::Playthrough::Tape.read(File.join(result.drift.report, "to-the-drift.tape"))

      assert_equal result.drift.frame, tape.frames
      assert_equal({ standing: 10, walked: 30 }, tape.moments, "the moments before the drift are still on it")
      { first => "first.png", second => "second.png" }.each do |cartridge, picture|
        assert png_colours_of(tape.play(cartridge).game.frame_gba) == png_in(result.drift.report, picture), picture
      end
    end
  end

  # THE TEXT FILE SAYS IT IN SHORT PLAIN SENTENCES: the frame, the moment before it, what was
  # down for the last second, which cartridges were played and how alike they had to be.
  def test_the_text_file_names_the_frame_the_moment_the_presses_and_the_settings
    first = plain
    second = turning

    with_report(first, second) do |result, _reports|
      words = File.read(File.join(result.drift.report, "report.txt"))
      on = result.drift.frame

      assert_includes words, "The two cartridges drifted on frame #{on}."
      assert_includes words, "The moment named before that frame was walked, on frame 30."
      assert_match(/the first cartridge: WALKER 0x\h{8}$/, words)
      assert_match(/the second cartridge: WALKER 0x\h{8}$/, words)
      assert_includes words, "frames 1 to 10: nothing down"
      assert_includes words, "frames 11 to 30: right"
      assert_includes words, "frames 31 to #{on}: nothing down"
      assert_includes words, "A frame differed when one of the pixels was a different colour."
    end
  end

  # THE LAST SECOND IS THE LAST SIXTY FRAMES, the drifting frame the last of them. This walk
  # is longer than a second and names no moment: the hold the second begins inside is said
  # from where the second begins, what came before it is not said at all, and the text says
  # that no moment came before.
  def test_the_presses_said_are_of_the_last_second_and_no_moment_is_said_plainly
    walk = RubyGBA.playthrough "a longer walk" do
      wait frames: 30
      hold :right, frames: 40
      wait frames: 60
    end
    first = plain
    second = walker(turns_red_at: 95)
    on = turned_on(second, walk.play(first).tape)

    Dir.mktmpdir("drift") do |somewhere|
      result = walk.compare(first, second, reports_in: somewhere)
      lines = File.read(File.join(result.drift.report, "report.txt")).lines.map(&:strip)

      assert_includes 90..129, on, "so the second before the drift begins part way through the walk"
      assert_equal on, result.drift.frame
      assert_includes lines, "No moment was named before that frame."
      assert_equal ["frames #{on - 59} to 70: right", "frames 71 to #{on}: nothing down"], lines.grep(/\Aframes? \d/)
    end
  end

  # The settings a comparison was given are all said, each in a sentence of its own, and the
  # stretches left out are said in words: the frames, and for moments the frames they came to.
  def test_the_text_file_says_every_setting_that_was_in_force
    settings = { share_may_differ: 0.01, frames_in_a_row: 2, ignoring_rectangles: [[0, 0, 240, 8]],
                 ignoring_frames: [1..5, 7...9, (..:standing), :standing...:walked] }

    with_report(plain, turning, **settings) do |result, _reports|
      words = File.read(File.join(result.drift.report, "report.txt"))

      assert_includes words, "A frame differed when more than 1 percent of the pixels that were looked at were a different colour."
      assert_includes words, "2 frames in a row had to differ before it was drift."
      assert_includes words, "240 by 8 pixels from column 0, row 0"
      assert_includes words, "not looked at: frames 1 to 5; frames 7 to 8; from the start to the moment standing (frames 1 to 10); " \
                             "from the moment standing to just before the moment walked (frames 10 to 29)."
    end
  end

  # One pixel of the screen is a very small share, and it is written out as a number a
  # person reads and never with an exponent.
  def test_a_very_small_share_is_written_out_in_full
    with_report(plain, turning, share_may_differ: 1.0 / PIXELS) do |result, _reports|
      assert_includes File.read(File.join(result.drift.report, "report.txt")), "more than 0.0026041667 percent of the pixels"
    end
  end

  # WITH SEVERAL FRAMES IN A ROW ASKED FOR, THE REPORT IS OF THE FRAME THE DRIFT BEGAN, which
  # by the time it is known to be drift both consoles have played past. This ground is red
  # for three frames while the box is walking, so each of the three is a different picture:
  # the folder is named for the first of them, its pictures are of that frame and not of
  # the frame the consoles had reached, and its tape ends there.
  def test_the_report_is_of_the_first_frame_of_a_stretch
    first = plain
    second = walker(turns_red_at: 20, red_for: 3)
    tape = walk_right.play(first).tape
    red_on = frames_where(second, tape) { |game| game.red?(0, 0) }
    began, reached = [red_on.first, red_on.last].map { |frame| png_colours_of(screen_on(second, tape, frame)) }

    with_report(first, second, frames_in_a_row: 3) do |result, _reports|
      folder = result.drift.report

      assert_equal red_on.last, result.frames, "it played to the end of the stretch"
      assert_equal "frame-0000#{red_on.first}", File.basename(folder)
      refute began == reached, "the box walked on while the ground was red"
      assert png_in(folder, "second.png") == began
      assert png_in(folder, "first.png") == png_colours_of(screen_on(first, tape, red_on.first))
      assert_equal red_on.first, RubyGBA::Diagnostics::Playthrough::Tape.read(File.join(folder, "to-the-drift.tape")).frames
    end
  end

  # A pixel that differs in a part of the screen that is not looked at is not marked: the
  # difference picture marks what made it a drift.
  def test_the_difference_picture_marks_only_pixels_that_were_looked_at
    with_report(plain, turning, ignoring_rectangles: [[0, 0, 240, 80]]) do |result, _reports|
      marked_rows = png_in(result.drift.report, "difference.png").each_slice(240).map { |row| row.count(MARKED) }

      assert_equal [0], marked_rows.first(80).uniq, "nothing is marked in the half that was left out"
      assert_equal [240], marked_rows.last(80).uniq, "and the whole ground is in the other, where the box is not"
    end
  end

  # NO DRIFT, OR NOWHERE TO WRITE, AND NOTHING IS WRITTEN — not even the folder that was named.
  def test_no_drift_or_no_place_writes_nothing
    cartridge = plain
    Dir.mktmpdir("drift") do |somewhere|
      reports = File.join(somewhere, "reports")

      refute walk_right.compare(cartridge, cartridge, reports_in: reports).drift?
      refute File.exist?(reports)
      assert_nil walk_right.compare(cartridge, turning).drift.report
      assert_empty Dir.children(somewhere)
    end
  end

  # --- a place that cannot be one, refused before anything is played ---

  # The cartridges here are nil, which no comparison could play: the place is refused first.
  def test_a_place_for_reports_that_is_a_file_or_is_not_a_path_is_refused
    Dir.mktmpdir("drift") do |somewhere|
      a_file = File.join(somewhere, "notes.txt").tap { |written| File.write(written, "not a folder") }

      [a_file, 42, true, ""].each do |wrong|
        err = assert_raises(ArgumentError) { walk_right.compare(nil, nil, reports_in: wrong) }

        assert_match(/reports_in/, err.message)
        assert_match(/folder/, err.message)
      end
    end
  end

  # A folder that is not there yet is made when there is a drift to report, so what is
  # looked at beforehand is the folder it would be made in: one that is really a file, or
  # that cannot be written to, will never hold it.
  def test_a_place_that_could_never_be_made_is_refused_before_anything_is_played
    Dir.mktmpdir("drift") do |somewhere|
      a_file = File.join(somewhere, "notes.txt").tap { |written| File.write(written, "not a folder") }
      locked = File.join(somewhere, "locked").tap { |folder| Dir.mkdir(folder, 0o555) }

      inside_a_file = assert_raises(ArgumentError) { walk_right.compare(nil, nil, reports_in: File.join(a_file, "reports", "today")) }
      inside_locked = assert_raises(ArgumentError) { walk_right.compare(nil, nil, reports_in: File.join(locked, "reports")) }

      assert_match(/notes\.txt is a file/, inside_a_file.message)
      assert_match(/locked cannot be written to/, inside_locked.message)
    end
  end

  # A report that cannot be written when the time comes does not lose the finding: the
  # error says the frame, and holds the drift. Here something that is not a folder already
  # has the name the report's folder needs.
  def test_a_report_that_cannot_be_written_still_says_where_the_drift_was
    first = plain
    second = turning
    on = turned_on(second, walk_right.play(first).tape)

    Dir.mktmpdir("drift") do |somewhere|
      File.write(File.join(somewhere, "frame-0000#{on}"), "in the way")
      err = assert_raises(RubyGBA::Diagnostics::Comparison::ReportNotWritten) { walk_right.compare(first, second, reports_in: somewhere) }

      assert_equal on, err.drift.frame
      assert_match(/drifted on frame #{on}\b/, err.message)
      assert_match(/reports_in/, err.message)
    end
  end
end
