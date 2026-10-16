# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "comparison_games"
require "png_reading"
require RubyGBA.root.join("examples/hero").to_s

# ONE PICTURE OF ONE FRAME ON TWO CARTRIDGES: the first cartridge's screen, the second's, and
# where the two differ, left to right in one file at twice the console's size. It is what a
# person looks at to see what a comparison found, so it is asked for by itself, for any frame.
#
# The two cartridges are the walker and a walker whose ground turns red part way through.
# What each showed on a frame is found by playing it on its own to that frame.
class TestComparisonSideBySidePicture < Minitest::Test
  include ComparisonGames
  include PNGReading

  WHITE = [255, 255, 255].freeze
  BLUE = [0, 0, 255].freeze
  RED = [255, 0, 0].freeze
  MARKED = [255, 0, 255].freeze

  # A panel is the console's screen at twice its size, and a gap stands between two panels.
  PANEL_WIDTH = 480
  PANEL_HEIGHT = 320
  GAP = 8
  THREE_PANELS = [(3 * PANEL_WIDTH) + (2 * GAP), PANEL_HEIGHT].freeze
  TWO_PANELS = [(2 * PANEL_WIDTH) + GAP, PANEL_HEIGHT].freeze

  private def plain = walker
  private def turning = walker(turns_red_at: 45)

  # The frame the turning cartridge's ground is first red, playing the walk on its own.
  private def turned_on(cartridge, tape) = first_frame(cartridge, tape) { |game| game.red?(0, 0) }

  # The screen a cartridge shows on one frame of a tape, played on its own, as a PNG holds
  # it. A walker shows three colours and no others.
  private def screen_on(cartridge, tape, frame)
    as_png = { Color.resolve(:white) => WHITE, Color.resolve(:blue) => BLUE, Color.resolve(:red) => RED }
    each_frame_of(cartridge, tape) { |game, played| return game.frame_gba.map { |colour| as_png.fetch(colour) } if played == frame }
  end

  # The path of a picture that is not there yet, in a folder that is taken away afterwards.
  private def with_place
    Dir.mktmpdir("side-by-side") { |somewhere| yield File.join(somewhere, "picture.png") }
  end

  # ONE PANEL OF A WRITTEN PICTURE, BACK AT THE CONSOLE'S SIZE: a screenful of pixels, a row
  # at a time. +which+ counts the panels from 0 at the left. Each of the console's pixels is
  # four in the file, and all four have to be the one colour.
  private def panel(png, which)
    width, = png_size(png)
    rows = png_pixels(png).each_slice(width).to_a
    left = which * (PANEL_WIDTH + GAP)
    (0...160).flat_map do |y|
      (0...240).map do |x|
        four = [rows[2 * y][left + (2 * x), 2], rows[(2 * y) + 1][left + (2 * x), 2]].flatten(1)

        assert_equal 1, four.uniq.size, "the pixel at (#{x}, #{y}) of panel #{which} is one colour at twice the size"
        four.first
      end
    end
  end

  # GIVEN A TAPE, TWO CARTRIDGES AND A FRAME, ONE PICTURE IS WRITTEN: the first screen, the
  # second and the difference, left to right, each at twice the console's size. The
  # difference marks every pixel that differs — here the whole ground, and none of the box,
  # which is white on both — and is grey everywhere else.
  def test_one_picture_holds_both_screens_and_the_difference
    first = plain
    second = turning
    tape = walk_right.play(first).tape
    on = turned_on(second, tape)
    screens = [first, second].map { |cartridge| screen_on(cartridge, tape, on) }
    differing = (0...PIXELS).reject { |at| screens[0][at] == screens[1][at] }

    with_place do |place|
      written = tape.write_side_by_side_picture(first, second, place, at: on)
      png = File.binread(place)
      difference = panel(png, 2)

      assert_equal place, written
      assert_equal THREE_PANELS, png_size(png)
      assert panel(png, 0) == screens[0], "the left panel is the first cartridge's screen"
      assert panel(png, 1) == screens[1], "the middle panel is the second's"
      assert_equal PIXELS - 64, differing.size, "everything but the box, which is eight pixels square"
      assert_equal differing, (0...PIXELS).select { |at| difference[at] == MARKED }
      assert((0...PIXELS).reject { |at| difference[at] == MARKED }.all? { |at| difference[at].uniq.size == 1 }, "the rest is grey")
    end
  end

  # ASKED TO LEAVE THE DIFFERENCE OUT, the picture is the two screens and nothing else.
  def test_the_difference_can_be_left_out
    first = plain
    second = turning
    tape = walk_right.play(first).tape
    on = turned_on(second, tape)

    with_place do |place|
      tape.write_side_by_side_picture(first, second, place, at: on, difference: false)
      png = File.binread(place)

      assert_equal TWO_PANELS, png_size(png)
      assert panel(png, 0) == screen_on(first, tape, on)
      assert panel(png, 1) == screen_on(second, tape, on)
    end
  end

  # TWO CARTRIDGES THAT SHOW THE SAME SCREEN ON THE FRAME give a third panel with no mark
  # in it: the first screen in grey. This frame is before the second one's ground turns.
  def test_two_screens_that_match_leave_the_difference_unmarked
    first = plain
    second = turning
    tape = walk_right.play(first).tape

    with_place do |place|
      tape.write_side_by_side_picture(first, second, place, at: 30)
      png = File.binread(place)
      difference = panel(png, 2)

      assert panel(png, 0) == panel(png, 1), "the two show the same screen on frame 30"
      assert_equal 0, difference.count(MARKED)
      assert_equal [1], difference.map { |pixel| pixel.uniq.size }.uniq, "every pixel of it is a grey"
      assert_equal 2, difference.uniq.size, "the ground and the box, each its own grey"
    end
  end

  # THE FRAME CAN BE SAID BY THE NAME OF A MOMENT, which is the frame that moment names.
  # The box has walked for twenty frames by then, so the picture is not the one before it.
  def test_the_frame_can_be_named_by_a_moment
    first = plain
    second = turning
    tape = walk_right.play(first).tape

    with_place do |place|
      tape.write_side_by_side_picture(first, second, place, at: :walked)
      at_the_moment = panel(File.binread(place), 0)

      assert_equal 30, tape.moments.fetch(:walked)
      assert at_the_moment == screen_on(first, tape, 30)
      refute at_the_moment == screen_on(first, tape, 29), "the box was still walking the frame before"
    end
  end

  # A SCRIPT WRITES THE SAME PICTURE ITS TAPE DOES. The script is played on the first
  # cartridge to learn the presses, as it is for a comparison, and both are played on those.
  def test_a_script_writes_the_picture_its_tape_writes
    first = plain
    second = turning
    tape = walk_right.play(first).tape
    on = turned_on(second, tape)

    Dir.mktmpdir("side-by-side") do |somewhere|
      of_script = walk_right.write_side_by_side_picture(first, second, File.join(somewhere, "script.png"), at: on)
      of_tape = tape.write_side_by_side_picture(first, second, File.join(somewhere, "tape.png"), at: on)

      assert_equal File.join(somewhere, "script.png"), of_script
      assert File.binread(of_script) == File.binread(of_tape), "the two files are the same picture"
    end
  end

  # A PART OF THE SCREEN THAT IS LEFT OUT IS NEVER MARKED, as in a drift report: the whole
  # ground differs, and only the half that was looked at is marked.
  def test_a_part_of_the_screen_left_out_is_not_marked
    first = plain
    second = turning
    tape = walk_right.play(first).tape

    with_place do |place|
      tape.write_side_by_side_picture(first, second, place, at: tape.frames, ignoring_rectangles: [[0, 0, 240, 80]])
      marked_rows = panel(File.binread(place), 2).each_slice(240).map { |row| row.count(MARKED) }

      assert_equal [0], marked_rows.first(80).uniq, "nothing is marked in the half that was left out"
      assert_equal [240], marked_rows.last(80).uniq, "and the whole ground is in the other, where the box is not"
    end
  end

  # TWO CARTRIDGES OUT OF STEP FROM POWER-ON ARE LED IN, each by its own lead-in, as they are
  # for a comparison: frame 30 is then the same frame of the game on both, and nothing is
  # marked. Without the lead-ins one is still on its logo.
  def test_each_cartridge_can_be_led_in_first
    first = walker(logo_for: 3)
    second = walker(logo_for: 12)
    tape = walk_right.play(first, lead_in: past_the_logo).tape

    with_place do |place|
      tape.write_side_by_side_picture(first, second, place, at: 30, lead_ins: [past_the_logo, past_the_logo])
      led_in = File.binread(place)

      assert_equal 0, panel(led_in, 2).count(MARKED)
      assert panel(led_in, 0) == panel(led_in, 1)
      assert_equal 1, panel(led_in, 0).count(WHITE) / 64, "the box is on both, so neither is a logo"
    end
  end

  # A tape recorded after a lead-in says so, and its picture is asked for with lead-ins as
  # its comparison is: with none, the same presses start somewhere else.
  def test_a_tape_recorded_after_a_lead_in_needs_lead_ins
    tape = walk_right.play(walker(logo_for: 3), lead_in: past_the_logo).tape

    with_place do |place|
      err = assert_raises(ArgumentError) { tape.write_side_by_side_picture(nil, nil, place, at: 30) }

      assert_match(/lead_ins:/, err.message)
      assert_match(/write_side_by_side_picture/, err.message)
    end
  end

  # BOTH CARTRIDGES CAN START FROM A SAVE, as they can for a comparison. The game is the hero
  # example, whose file screen shows how far the walk in each file went: from the save both
  # panels are the file screen a playthrough started from that save shows, and from
  # power-on they are not. A tape recorded from a save asks for one.
  def test_both_cartridges_can_start_from_a_save
    cartridge = Hero.build_rom(out: StringIO.new, err: StringIO.new, profile: false)
    saved = walk_and_save.play(cartridge).save
    file_read = RubyGBA.playthrough "hero: the file screen" do
      wait frames: 20
      moment :read
    end

    Dir.mktmpdir("side-by-side") do |somewhere|
      from_the_save = file_read.play(cartridge, save: saved, pictures_in: somewhere)
      file_screen = png_pixels(File.binread(from_the_save.picture_files.fetch(:read)))
      with_save, without = [{ save: saved }, {}].map do |settings|
        place = File.join(somewhere, "side-by-side-#{settings.size}.png")
        File.binread(file_read.write_side_by_side_picture(cartridge, cartridge, place, at: :read, **settings))
      end
      needs_one = assert_raises(ArgumentError) { from_the_save.tape.write_side_by_side_picture(nil, nil, File.join(somewhere, "tape.png"), at: 1) }

      assert panel(with_save, 0) == file_screen, "the first cartridge is in the save"
      assert panel(with_save, 1) == file_screen, "and so is the second"
      refute panel(without, 0) == file_screen, "from power-on the file is empty"
      assert_match(/save:/, needs_one.message)
    end
  end

  # FILE 1, NEW GAME, RIGHT for twenty frames and START to save, then a wait for the save
  # to be written, which the hero example does a piece at a time as it goes round its loop.
  private def walk_and_save
    RubyGBA.playthrough "hero: walk and save" do
      wait frames: 10
      press :a
      wait frames: 4
      press :a
      wait frames: 4
      hold :right, frames: 20
      press :start
      wait frames: 30
    end
  end

  # --- what cannot be a picture, refused before anything is played ---
  #
  # The cartridges in these are nil, which nothing could play: each is refused first.

  private def a_tape = walk_right.play(plain).tape

  # A FRAME THE TAPE DOES NOT REACH is refused, saying how many frames the tape plays.
  def test_a_frame_past_the_end_of_the_tape_is_refused
    tape = a_tape

    with_place do |place|
      err = assert_raises(ArgumentError) { tape.write_side_by_side_picture(nil, nil, place, at: 61) }

      assert_equal 60, tape.frames
      assert_match(/`at:` was 61\b/, err.message)
      assert_match(/60 frames/, err.message)
      refute File.exist?(place)
    end
  end

  # A MOMENT THE TAPE DOES NOT NAME is refused, naming the ones it does.
  def test_a_moment_that_was_not_named_is_refused
    tape = a_tape

    with_place do |place|
      err = assert_raises(ArgumentError) { tape.write_side_by_side_picture(nil, nil, place, at: :at_the_door) }

      assert_match(/:at_the_door/, err.message)
      assert_match(/:standing, :walked/, err.message)
    end
  end

  # A playthrough that names no moment says so, where it would have listed them.
  def test_a_moment_asked_of_a_playthrough_that_names_none_is_refused
    waiting = RubyGBA.playthrough("only waiting") { wait frames: 5 }

    with_place do |place|
      err = assert_raises(ArgumentError) { waiting.write_side_by_side_picture(nil, nil, place, at: :at_the_door) }

      assert_match(/names no moments/, err.message)
    end
  end

  # What is neither a frame nor a moment's name is refused: frames are counted from 1, and a
  # moment is named with a symbol.
  def test_a_frame_that_is_no_frame_and_no_moment_is_refused
    tape = a_tape

    with_place do |place|
      [0, -3, 4.5, "walked", nil].each do |wrong|
        err = assert_raises(ArgumentError) { tape.write_side_by_side_picture(nil, nil, place, at: wrong) }

        assert_match(/`at:` was #{Regexp.escape(wrong.inspect)}\./, err.message)
        assert_match(/counted from 1/, err.message)
      end
    end
  end

  # A PLACE THE PICTURE COULD NEVER BE WRITTEN is refused: something that is not a path, a
  # folder where the file was meant, a file already there that cannot be written over, and
  # a file inside a folder that cannot be written to or inside something that is itself a
  # file.
  def test_a_place_that_cannot_be_written_is_refused
    tape = a_tape
    Dir.mktmpdir("side-by-side") do |somewhere|
      a_file = File.join(somewhere, "notes.txt").tap { |written| File.write(written, "not a folder") }
      locked = File.join(somewhere, "locked").tap { |folder| Dir.mkdir(folder, 0o555) }
      kept = File.join(somewhere, "kept.png").tap { |written| File.write(written, "not to be changed") }
      File.chmod(0o444, kept)

      { 42 => /path of a file/, "" => /path of a file/, somewhere => /is a folder/,
        kept => /That file cannot be written to/,
        File.join(a_file, "picture.png") => /notes\.txt is a file/,
        File.join(locked, "pictures", "picture.png") => /locked cannot be written to/ }.each do |wrong, why|
        err = assert_raises(ArgumentError) { tape.write_side_by_side_picture(nil, nil, wrong, at: 30) }

        assert_match(why, err.message)
      end
    end
  end

  # A SCRIPT SAYS ITS MOMENTS WHERE IT IS DECLARED, so a moment it does not name is refused
  # before it is played. How long it plays is not known until it has been, so a frame past
  # its end is refused once the script has been played on the first cartridge.
  def test_a_script_refuses_a_moment_it_does_not_name_and_a_frame_past_its_end
    cartridge = plain

    with_place do |place|
      no_moment = assert_raises(ArgumentError) { walk_right.write_side_by_side_picture(nil, nil, place, at: :at_the_door) }
      too_far = assert_raises(ArgumentError) { walk_right.write_side_by_side_picture(cartridge, cartridge, place, at: 61) }

      assert_match(/no moment named :at_the_door/, no_moment.message)
      assert_match(/:standing, :walked/, no_moment.message)
      assert_match(/`at:` was 61\b/, too_far.message)
      assert_match(/60 frames/, too_far.message)
      refute File.exist?(place)
    end
  end

  # A setting of a comparison that a picture has no use for is refused, naming the ones it has.
  def test_a_setting_a_picture_does_not_have_is_refused
    with_place do |place|
      err = assert_raises(ArgumentError) { walk_right.write_side_by_side_picture(nil, nil, place, at: 30, carrying_on: true) }

      assert_match(/no setting named :carrying_on/, err.message)
      assert_match(/`ignoring_rectangles:`/, err.message)
    end
  end

  # A picture asked for with no frame said is refused in the same words as a frame that is
  # no frame, and not in Ruby's own.
  def test_a_picture_with_no_frame_said_is_refused
    with_place do |place|
      err = assert_raises(ArgumentError) { walk_right.write_side_by_side_picture(nil, nil, place) }

      assert_match(/`at:` was nil/, err.message)
      assert_match(/name of a moment/, err.message)
    end
  end

  # Whether the difference is there is yes or no, and anything else is refused.
  def test_a_difference_that_is_not_yes_or_no_is_refused
    tape = a_tape

    with_place do |place|
      err = assert_raises(ArgumentError) { tape.write_side_by_side_picture(nil, nil, place, at: 30, difference: :pink) }

      assert_match(/`difference:` was :pink/, err.message)
      assert_match(/true or false/, err.message)
    end
  end

  # A FOLDER THAT IS NOT THERE YET IS MADE, as a comparison makes the folder of its reports,
  # and a file already there under the picture's name is written over.
  def test_a_folder_that_is_not_there_is_made_and_a_file_is_written_over
    cartridge = plain
    tape = walk_right.play(cartridge).tape

    Dir.mktmpdir("side-by-side") do |somewhere|
      place = File.join(somewhere, "pictures", "today", "walked.png")

      assert_equal place, tape.write_side_by_side_picture(cartridge, cartridge, place, at: :walked)
      assert_equal THREE_PANELS, png_size(File.binread(place))
      tape.write_side_by_side_picture(cartridge, cartridge, place, at: :walked, difference: false)

      assert_equal TWO_PANELS, png_size(File.binread(place)), "the second picture took the place of the first"
    end
  end
end
