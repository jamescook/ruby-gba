# frozen_string_literal: true

require "test_helper"
require "stringio"
require "comparison_games"
require_relative "../../../examples/hero"

# A COMPARISON: TWO CARTRIDGES PLAYED SIDE BY SIDE ON THE SAME PRESSES, and the first frame on
# which their pictures differ. It is how somebody rebuilding a game learns where theirs has
# drifted from the original, and how a framework change that moves something a frame early is
# caught without two people squinting at two screens.
#
# The second cartridge in these tests is the first one built again with one thing changed on
# purpose. Where the two first differ is worked out by playing a cartridge on its own and
# asking the game — never read off the comparison, which is the thing being tested.
class TestComparison < Minitest::Test
  include ComparisonGames

  # A white square on a tiled screen, put there one of two ways: as a tile of a background,
  # or as a sprite standing where that tile would be. The console builds the same picture
  # out of different parts.
  private def white_square(drawn_as:)
    RubyGBA.build("SQUARE", out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image :block, "#" => :white do
        (["########"] * 8).join("\n")
      end
      if drawn_as == :tile
        tiles :set, "#" => :block
        background :ground, tiles: :set, map: ["     ", "     ", "     ", "    #"]
      else
        sprite :block, at: [32, 24]
      end
      game_loop {}
    end
  end

  private def hero(**settings)
    Hero.build_rom(out: StringIO.new, err: StringIO.new, profile: false, settings: settings)
  end

  # Every picture a cartridge shows while a tape is played on it, each as the colours on
  # the screen.
  private def pictures_of(cartridge, tape)
    [].tap { |shown| each_frame_of(cartridge, tape) { |game, _frame| shown << game.frame_gba } }
  end

  # THE SAME CARTRIDGE TWICE NEVER DRIFTS, over several hundred frames of a real game: out of
  # the file screen and walking about.
  def test_a_cartridge_does_not_drift_from_itself
    wander = RubyGBA.playthrough "hero: new game, then wander" do
      wait frames: 10
      press :a
      wait frames: 4
      press :a
      wait frames: 4
      hold :right, frames: 90
      hold :down, :right, frames: 60
      hold :up, frames: 120
      press :start
      wait frames: 60
    end
    cartridge = hero
    result = wander.compare(cartridge, cartridge)

    refute result.drift?
    assert_nil result.drift
    assert_equal 354, result.frames, "every frame of the script was played and compared"
  end

  # A HERO THAT WALKS FASTER drifts on the first frame the world has moved under him, and
  # not before: the same game built again with a quicker hero is the same picture through
  # the file screen and while he stands. The world is drawn in the gap before a frame from
  # where the hero stood then, so it shows a step one frame after the game took it.
  def test_a_changed_walking_speed_drifts_on_the_first_frame_the_world_has_moved
    out_and_right = RubyGBA.playthrough "hero: new game, walk right" do
      wait frames: 10
      press :a
      wait frames: 4
      press :a
      wait frames: 4
      moment :standing
      hold :right, frames: 20
      moment :walked
    end
    slow = hero
    stepped_on = first_frame(slow, out_and_right.play(slow).tape) { |game| game.var(:px) > Hero::START_X }
    result = out_and_right.compare(slow, hero(speed: 3))

    assert_operator stepped_on, :>, 22, "the hero first steps after RIGHT goes down, on frame 23"
    assert_equal stepped_on + 1, result.drift.frame
    assert_equal :standing, result.drift.moment
  end

  # A CARTRIDGE WITH A COLOUR CHANGED drifts on the first frame that colour is on screen, and
  # not before: one of these two turns its ground red part way through and the other never
  # does. The frame it turns is asked of that cartridge on its own.
  def test_a_changed_colour_drifts_on_the_first_frame_it_is_on_screen
    plain = walker
    turning = walker(turns_red_at: 45)
    turned_on = first_frame(turning, walk_right.play(plain).tape) { |game| game.red?(0, 0) }
    result = walk_right.compare(plain, turning)

    assert_operator turned_on, :>, 30, "the ground turns after the walk, well into the script"
    assert result.drift?
    assert_equal turned_on, result.drift.frame
    assert_equal :walked, result.drift.moment, "the moment before it"
    assert_equal turned_on, result.frames, "and it stopped there"
  end

  # THE MOMENT BEFORE A DRIFT IS THE LAST ONE NAMED BEFORE THAT FRAME WAS PLAYED. A moment
  # names the frame just played, so one that names the very frame the two drift on was said
  # after it, and is not the one before.
  def test_a_moment_naming_the_frame_of_the_drift_is_not_the_moment_before_it
    plain = walker
    turning = walker(turns_red_at: 20)
    waiting = RubyGBA.playthrough("wait") { wait frames: 40 }
    turned_on = first_frame(turning, waiting.play(plain).tape) { |game| game.red?(0, 0) }
    marked = RubyGBA.playthrough "a moment on the frame it turns" do
      wait frames: 5
      moment :early
      wait frames: turned_on - 5
      moment :as_it_turns
      wait frames: 5
    end
    drift = marked.compare(plain, turning).drift

    assert_equal turned_on, marked.play(plain).moments[:as_it_turns]
    assert_equal turned_on, drift.frame
    assert_equal :early, drift.moment
  end

  # A drift before the script has named any moment has none to be placed by.
  def test_a_drift_before_any_moment_names_none
    waiting = RubyGBA.playthrough("wait") { wait frames: 30 }
    result = waiting.compare(walker, walker(turns_red_at: 5))

    assert result.drift?
    assert_nil result.drift.moment
  end

  # THE SAME COLOURS ARE THE SAME PICTURE, whatever the console built them from. The emulator
  # keeps a note beside each pixel of which part of the display drew it, and that note is not
  # something anybody sees: a rebuilt game that reaches the original's picture by a
  # different route has not drifted from it.
  def test_the_same_colours_drawn_by_different_parts_of_the_display_do_not_drift
    waiting = RubyGBA.playthrough("wait") { wait frames: 12 }
    as_a_tile = white_square(drawn_as: :tile)
    as_a_sprite = white_square(drawn_as: :sprite)
    tape = waiting.play(as_a_tile).tape
    shown = pictures_of(as_a_tile, tape)

    assert_includes shown.last, Color.resolve(:white), "the square is on screen"
    assert shown == pictures_of(as_a_sprite, tape), "the two show the same colours on every frame"
    refute waiting.compare(as_a_tile, as_a_sprite).drift?
  end

  # --- how alike two pictures have to be ---

  # A FEW PIXELS OUT IS DRIFT UNLESS THAT SHARE OF THE SCREEN MAY DIFFER. One of these two
  # draws three pixels the other does not, from a frame asked of it on its own. With nothing
  # said that is drift; so it is while fewer than three may differ; and once three may, the
  # two are alike for the whole script.
  def test_a_few_pixels_out_is_drift_until_that_share_may_differ
    waiting = RubyGBA.playthrough("wait") { wait frames: 50 }
    plain = walker
    specked = walker(specks: 3)
    specked_on = first_frame(specked, waiting.play(plain).tape) { |game| specks_showing?(game) }

    assert_operator specked_on, :>, SPECKS_FROM
    assert_equal specked_on, waiting.compare(plain, specked).drift.frame
    assert_equal specked_on, waiting.compare(plain, specked, share_may_differ: Rational(2, PIXELS)).drift.frame
    refute waiting.compare(plain, specked, share_may_differ: Rational(3, PIXELS)).drift?, "exactly that many is still alike"
    refute waiting.compare(plain, specked, share_may_differ: 0.01).drift?
  end

  # A SHARE WRITTEN AS A DECIMAL MEANS THE PIXELS IT WAS WORKED OUT FROM. Fifty-five pixels
  # of the screen, written `55.0 / 38_400`, is a number that multiplied back up comes out a
  # hair under fifty-five — so it is the shares that are compared, never a count worked back.
  def test_a_share_written_as_a_decimal_allows_the_pixels_it_was_worked_out_from
    waiting = RubyGBA.playthrough("wait") { wait frames: 50 }
    plain = walker
    specked = walker(specks: 55)

    assert_operator (55.0 / PIXELS) * PIXELS, :<, 55, "the number that makes this worth a test"
    refute waiting.compare(plain, specked, share_may_differ: 55.0 / PIXELS).drift?
    assert waiting.compare(plain, specked, share_may_differ: 54.0 / PIXELS).drift?
  end

  # THE TWO SETTINGS TOGETHER: a frame has to be over the share, for that many frames running.
  def test_the_share_and_the_frames_in_a_row_are_asked_together
    waiting = RubyGBA.playthrough("wait") { wait frames: 50 }
    plain = walker
    specked = walker(specks: 3)
    tape = waiting.play(plain).tape
    specked_on = first_frame(specked, tape) { |game| specks_showing?(game) }
    over_the_share = tape.compare(plain, specked, share_may_differ: Rational(2, PIXELS), frames_in_a_row: 4)

    assert_equal specked_on, over_the_share.drift.frame
    assert_equal specked_on + 3, over_the_share.frames
    refute tape.compare(plain, specked, share_may_differ: Rational(3, PIXELS), frames_in_a_row: 4).drift?
  end

  # A DIFFERENCE HAS TO LAST AS MANY FRAMES IN A ROW AS WAS ASKED FOR. One of these two turns
  # its ground red for three frames and then back. Asked for three in a row that is drift,
  # reported on the first of the three and found on the last; asked for four it is not.
  def test_a_difference_is_drift_once_it_lasts_the_frames_in_a_row_asked_for
    waiting = RubyGBA.playthrough "wait" do
      wait frames: 10
      moment :settled
      wait frames: 50
    end
    plain = walker
    flashing = walker(turns_red_at: 25, red_for: 3)
    red_on = frames_where(flashing, waiting.play(plain).tape) { |game| game.red?(0, 0) }
    lasting = waiting.compare(plain, flashing, frames_in_a_row: 3)

    assert_equal 3, red_on.size, "the ground is red for three frames"
    assert_equal red_on.first, waiting.compare(plain, flashing).drift.frame, "with nothing said, one frame is enough"
    assert_equal red_on.first, lasting.drift.frame, "the first frame of the stretch"
    assert_equal :settled, lasting.drift.moment
    assert_equal red_on.last, lasting.frames, "found once the third had been seen"
    refute waiting.compare(plain, flashing, frames_in_a_row: 4).drift?
  end

  # THE MOMENT REPORTED IS THE ONE BEFORE THE STRETCH BEGAN, not the last one named by the
  # time the stretch had lasted long enough. This script names a moment on the second of
  # the three red frames, so the stretch runs across it and across two of the script's steps.
  def test_a_moment_named_inside_a_stretch_is_not_the_moment_before_it
    plain = walker
    flashing = walker(turns_red_at: 25, red_for: 3)
    waiting = RubyGBA.playthrough("wait") { wait frames: 60 }
    red_on = frames_where(flashing, waiting.play(plain).tape) { |game| game.red?(0, 0) }
    marked = RubyGBA.playthrough "a moment in the middle of the flash" do
      wait frames: 10
      moment :settled
      wait frames: red_on[1] - 10
      moment :mid_flash
      wait frames: 20
    end
    drift = marked.compare(plain, flashing, frames_in_a_row: 3).drift

    assert_equal red_on[1], marked.play(plain).moments[:mid_flash]
    assert_equal red_on.first, drift.frame
    assert_equal :settled, drift.moment
  end

  # A STRETCH THAT ENDS IS FORGOTTEN: the frames of one do not count toward the next. This
  # cartridge's ground is red for three frames, the two are alike again, and then it draws
  # its specks for good. Asked for four in a row, the drift is where the specks begin.
  def test_a_stretch_that_ended_does_not_count_toward_the_next
    waiting = RubyGBA.playthrough("wait") { wait frames: 60 }
    plain = walker
    flashing_then_specked = walker(turns_red_at: 15, red_for: 3, specks: 3)
    tape = waiting.play(plain).tape
    red_on = frames_where(flashing_then_specked, tape) { |game| game.red?(0, 0) }
    specked_on = first_frame(flashing_then_specked, tape) { |game| specks_showing?(game) }

    assert_operator specked_on, :>, red_on.last + 1, "the two are alike between the flash and the specks"
    assert_equal specked_on, waiting.compare(plain, flashing_then_specked, frames_in_a_row: 4).drift.frame
  end

  # A stretch the tape runs out on, before it has lasted long enough, is not drift.
  def test_a_stretch_the_tape_runs_out_on_is_not_drift
    waiting = RubyGBA.playthrough("wait") { wait frames: 40 }
    plain = walker
    turning = walker(turns_red_at: 25)

    assert waiting.compare(plain, turning).drift?, "the two do differ before the tape ends"
    refute waiting.compare(plain, turning, frames_in_a_row: 100).drift?
  end

  # A PART OF THE SCREEN CAN BE LEFT OUT OF THE COUNT. The quicker of these two boxes pulls
  # ahead along one strip of the screen: rows 60 to 67, and never past column 87. With that
  # strip left out the two are alike; in two pieces, the same. Left out only as far as
  # column 49, they drift on the first frame the quicker box shows past it.
  def test_a_difference_inside_a_rectangle_left_out_is_not_drift
    slow = walker(speed: 2)
    fast = walker(speed: 3)
    past_column_49_on = first_frame(fast, walk_right.play(slow).tape) { |game| game.white?(50, 60) && game.blue?(50, 59) }
    too_narrow = walk_right.compare(slow, fast, ignoring_rectangles: [[20, 60, 30, 8]])

    refute walk_right.compare(slow, fast, ignoring_rectangles: [[20, 60, 68, 8]]).drift?
    refute walk_right.compare(slow, fast, ignoring_rectangles: [[20, 60, 30, 8], [50, 60, 38, 8]]).drift?
    assert_equal past_column_49_on, too_narrow.drift.frame
    assert_operator past_column_49_on, :>, walk_right.compare(slow, fast).drift.frame, "later than with nothing left out"
  end

  # THE SHARE IS A SHARE OF THE PIXELS LOOKED AT. With the top half of the screen left out
  # there are 19,200 left, and three pixels out among them is three in 19,200: a share
  # worked out against the whole screen would be half as strict as it says.
  def test_the_share_is_of_the_pixels_that_are_looked_at
    waiting = RubyGBA.playthrough("wait") { wait frames: 50 }
    plain = walker
    specked = walker(specks: 3)
    bottom_half = { ignoring_rectangles: [[0, 0, 240, 80]] }

    assert_operator SPECK_Y, :>=, 80, "the specks are in the half that is looked at"
    refute waiting.compare(plain, specked, share_may_differ: Rational(3, PIXELS / 2), **bottom_half).drift?
    assert waiting.compare(plain, specked, share_may_differ: Rational(3, PIXELS), **bottom_half).drift?
  end

  # --- a setting that makes no sense, each refused before a frame is played ---
  #
  # These hand over no cartridges at all, which is the proof of "before": had anything been
  # played, it would have failed on that first.

  def test_a_setting_compare_does_not_have_is_refused_with_the_ones_it_has
    err = assert_raises(ArgumentError) { walk_right.compare(nil, nil, pixels_differing: 0.1) }

    assert_match(/pixels_differing/, err.message)
    assert_match(/share_may_differ/, err.message)
    assert_match(/frames_in_a_row/, err.message)
    assert_match(/ignoring_rectangles/, err.message)
    assert_match(/ignoring_frames/, err.message)
  end

  def test_a_share_of_pixels_outside_nought_to_one_is_refused
    [-0.1, 1.5, "half", nil, true, Float::NAN, Float::INFINITY, Complex(0.5, 0)].each do |wrong|
      err = assert_raises(ArgumentError) { walk_right.compare(nil, nil, share_may_differ: wrong) }

      assert_match(/share_may_differ/, err.message)
      assert_match(/from 0 to 1/, err.message)
    end
  end

  def test_a_count_of_frames_in_a_row_below_one_is_refused
    [0, -2, 1.5, "3"].each do |wrong|
      err = assert_raises(ArgumentError) { walk_right.compare(nil, nil, frames_in_a_row: wrong) }

      assert_match(/frames_in_a_row/, err.message)
      assert_match(/whole number, 1 or more/, err.message)
    end
  end

  # A rectangle is four whole numbers, and the commonest slip is one rectangle written
  # without the list around it.
  def test_a_rectangle_that_is_not_four_whole_numbers_is_refused_with_how_to_write_one
    [[0, 128, 240, 32], [[0, 128, 240]], [[0, 0, 0, 8]], [[0, 0, 8.5, 8]], "bar", nil, {}].each do |wrong|
      err = assert_raises(ArgumentError) { walk_right.compare(nil, nil, ignoring_rectangles: wrong) }

      assert_match(/ignoring_rectangles/, err.message)
      assert_match(/\[\[0, 128, 240, 32\]\]/, err.message, "it shows one written out")
    end
  end

  def test_a_rectangle_that_reaches_off_the_screen_is_refused
    [[[230, 0, 20, 10]], [[0, 150, 10, 20]], [[-1, 0, 10, 10]]].each do |wrong|
      err = assert_raises(ArgumentError) { walk_right.compare(nil, nil, ignoring_rectangles: wrong) }

      assert_match(/off the screen/, err.message)
      assert_match(/240/, err.message)
      assert_match(/160/, err.message)
    end
  end

  # A rectangle that reaches the very edge of the screen is on it.
  def test_a_rectangle_up_to_the_edge_of_the_screen_is_taken
    assert_equal 60, walk_right.compare(walker, walker, ignoring_rectangles: [[0, 0, 240, 160]]).frames
  end

  # A TAPE IS COMPARED IN PLACE OF A SCRIPT, here one read back from the text of a file: the
  # box of the quicker cartridge has gone further on the first frame it moves.
  def test_a_tape_is_compared_in_place_of_a_script
    slow = walker(speed: 2)
    fast = walker(speed: 3)
    tape = RubyGBA::Diagnostics::Playthrough::Tape.parse(walk_right.play(slow).tape.to_s)
    moved_on = first_frame(slow, tape) { |game| !game.white?(20, 60) }
    result = tape.compare(slow, fast)

    assert_includes 11..12, moved_on, "RIGHT goes down on frame 11"
    assert_equal moved_on, result.drift.frame
    assert_equal :standing, result.drift.moment
    assert_equal result, walk_right.compare(slow, fast), "and the script it came from says the same"
    refute tape.compare(slow, slow).drift?
  end

  # THE SECOND CARTRIDGE IS FED WHAT THE FIRST ONE DID. A script that walks until the game
  # has counted twenty paces watches the first cartridge to know when to stop, and the
  # second is handed that walk frame for frame. These two show the same picture for the same
  # presses and count their paces differently — so had each been left to watch itself, one
  # would have stopped walking sooner and the pictures would differ; and had the second been
  # the one watched, the walk would be the other length.
  def test_a_script_that_watches_the_game_watches_the_first_cartridge
    twenty_paces = RubyGBA.playthrough "walk twenty paces" do
      wait frames: 10
      hold_until("the box has taken twenty paces", :right) { |game| game.var(:paces) >= 20 }
      moment :there
      wait frames: 10
    end
    plain = walker
    hurried = walker(counts_by: 2)
    watching_plain = twenty_paces.compare(plain, hurried)
    watching_hurried = twenty_paces.compare(hurried, plain)

    refute watching_plain.drift?
    refute watching_hurried.drift?
    assert_equal twenty_paces.play(plain).frames, watching_plain.frames
    assert_equal twenty_paces.play(hurried).frames, watching_hurried.frames
    assert_equal 10, watching_plain.frames - watching_hurried.frames, "ten frames fewer to count twenty in twos"
  end
end
