# frozen_string_literal: true

require "test_helper"
require "comparison_games"

# STRETCHES OF A PLAYTHROUGH LEFT OUT OF A COMPARISON. Both cartridges are still played
# through a stretch that is left out; what differs inside it is simply not counted. A stretch
# is said as a range of frame numbers, or as a range from one named moment to another.
#
# The cartridge compared against the plain one here flashes its ground red for three frames
# and, later, draws three specks for good: two differences, on frames asked of that cartridge
# on its own.
class TestComparisonIgnoringFrames < Minitest::Test
  runs_on :reference

  include ComparisonGames

  private def flashing_then_specked = walker(turns_red_at: 15, red_for: 3, specks: 3)

  private def waiting = RubyGBA.playthrough("wait") { wait frames: 60 }

  # The frames the ground is red on, and the first frame the specks show.
  private def differences_of(cartridge, tape)
    [frames_where(cartridge, tape) { |game| game.red?(0, 0) }, first_frame(cartridge, tape) { |game| specks_showing?(game) }]
  end

  # A DRIFT INSIDE A RANGE OF FRAMES LEFT OUT IS NOT DRIFT, and the comparison carries on to
  # the next one outside it.
  def test_a_drift_inside_a_range_of_frames_left_out_is_passed_over
    plain = walker
    changed = flashing_then_specked
    red_on, specked_on = differences_of(changed, waiting.play(plain).tape)

    assert_equal red_on.first, waiting.compare(plain, changed).drift.frame, "with nothing left out, the flash is the drift"
    assert_equal specked_on, waiting.compare(plain, changed, ignoring_frames: [red_on.first..red_on.last]).drift.frame
  end

  # A DRIFT THAT BEGINS INSIDE A STRETCH LEFT OUT AND IS STILL THERE WHEN IT ENDS is reported
  # on the first frame after the stretch. This ground turns red and stays red.
  def test_a_drift_still_there_when_a_stretch_ends_is_reported_on_the_frame_after
    plain = walker
    turning = walker(turns_red_at: 15)
    turned_on = first_frame(turning, waiting.play(plain).tape) { |game| game.red?(0, 0) }
    result = waiting.compare(plain, turning, ignoring_frames: [1..(turned_on + 5)])

    assert_equal turned_on + 6, result.drift.frame
    assert_equal turned_on + 6, result.frames
  end

  # A RANGE IS A RUBY RANGE, and means what one means: it can leave its last frame out, run
  # on to the end of the playthrough, or start from its beginning. Several can be given.
  def test_a_range_can_leave_its_end_out_or_have_no_end_or_no_start
    plain = walker
    changed = flashing_then_specked
    red_on, specked_on = differences_of(changed, waiting.play(plain).tape)
    drift_ignoring = ->(*stretches) { waiting.compare(plain, changed, ignoring_frames: stretches).drift&.frame }

    assert_equal red_on.last, drift_ignoring.call(red_on.first...red_on.last), "the last red frame is looked at"
    assert_nil drift_ignoring.call((red_on.first..)), "nothing from the flash on is looked at"
    assert_equal specked_on, drift_ignoring.call((..red_on.last))
    assert_nil drift_ignoring.call(red_on.first..red_on.last, (specked_on..))
  end

  # A FRAME THAT IS NOT LOOKED AT BREAKS A RUN OF DIFFERING FRAMES. Nothing is known about
  # that frame, so the ones either side of it are not frames in a row: with the middle of the
  # three red frames left out there are never two together.
  def test_a_frame_left_out_breaks_a_run_of_differing_frames
    plain = walker
    changed = flashing_then_specked
    red_on, specked_on = differences_of(changed, waiting.play(plain).tape)
    two_in_a_row = waiting.compare(plain, changed, frames_in_a_row: 2)
    with_the_middle_out = waiting.compare(plain, changed, frames_in_a_row: 2, ignoring_frames: [red_on[1]..red_on[1]])

    assert_equal red_on.first, two_in_a_row.drift.frame
    assert_equal specked_on, with_the_middle_out.drift.frame
  end

  # A STRETCH CAN RUN FROM ONE NAMED MOMENT TO ANOTHER, which is the form that survives the
  # script gaining a step: frame numbers all move, and the moments move with the game. It is
  # the frames the two moments name and every frame between, on a script and on its tape.
  def test_a_stretch_can_run_from_one_named_moment_to_another
    plain = walker
    changed = flashing_then_specked
    red_on, specked_on = differences_of(changed, waiting.play(plain).tape)
    marked = RubyGBA.playthrough "moments round the flash" do
      wait frames: red_on.first
      moment :flash_starts
      wait frames: 2
      moment :flash_ends
      wait frames: 40
    end
    the_flash = { ignoring_frames: [:flash_starts..:flash_ends] }

    assert_equal({ flash_starts: red_on.first, flash_ends: red_on.last }, marked.play(plain).moments)
    assert_equal specked_on, marked.compare(plain, changed, **the_flash).drift.frame
    assert_equal :flash_ends, marked.compare(plain, changed, **the_flash).drift.moment, "the moment before the drift it went on to"
    assert_equal specked_on, marked.play(plain).tape.compare(plain, changed, **the_flash).drift.frame
    assert_equal red_on.last, marked.compare(plain, changed, ignoring_frames: [:flash_starts...:flash_ends]).drift.frame
  end

  # --- a stretch that makes no sense, each refused before a frame is played ---
  #
  # These hand over no cartridges at all, which is the proof of "before": had anything been
  # played, it would have failed on that first.

  # A NAME NO MOMENT HAS is refused with the names there are, on a script — before the
  # script is played, since a script says its moments where it is declared — and on a tape.
  def test_a_moment_that_is_not_declared_is_refused_with_the_ones_that_are
    tape = walk_right.play(walker).tape
    [walk_right, tape].each do |played|
      err = assert_raises(ArgumentError) { played.compare(nil, nil, ignoring_frames: [:standing..:at_the_door]) }

      assert_match(/:at_the_door/, err.message)
      assert_match(/:standing, :walked/, err.message, "the moments there are")
    end
  end

  def test_a_moment_named_in_a_playthrough_with_none_is_refused
    err = assert_raises(ArgumentError) { waiting.compare(nil, nil, ignoring_frames: [(:title..)]) }

    assert_match(/:title/, err.message)
    assert_match(/names no moments/, err.message)
  end

  # Two moments the wrong way round are a range with nothing in it, and say so with the
  # range written the right way.
  def test_two_moments_in_the_wrong_order_are_refused_with_the_right_one
    err = assert_raises(ArgumentError) { walk_right.compare(nil, nil, ignoring_frames: [:walked..:standing]) }

    assert_match(/:walked\.\.:standing/, err.message)
    assert_match(/:standing\.\.:walked/, err.message)
  end

  # Frames are counted from 1.
  def test_a_range_of_frames_that_starts_below_one_is_refused
    [0..5, -3..2].each do |wrong|
      err = assert_raises(ArgumentError) { waiting.compare(nil, nil, ignoring_frames: [wrong]) }

      assert_match(/ignoring_frames/, err.message)
      assert_match(/counted from 1/, err.message)
    end
  end

  def test_a_range_of_frames_with_no_frame_in_it_is_refused
    [10..5, 5...5, (...1), :standing...:standing].each do |wrong|
      err = assert_raises(ArgumentError) { walk_right.compare(nil, nil, ignoring_frames: [wrong]) }

      assert_match(/ignoring_frames/, err.message)
      assert_match(/no frame/, err.message)
    end
  end

  # A range the wrong way round is shown the right way round, with the dots it was written with.
  def test_a_range_the_wrong_way_round_is_shown_the_right_way_round
    err = assert_raises(ArgumentError) { waiting.compare(nil, nil, ignoring_frames: [10...5]) }

    assert_match(/5\.\.\.10/, err.message)
  end

  # TWO MOMENTS CAN NAME THE SAME FRAME, when one is declared straight after the other, and
  # then three dots between them leave out the only frame there is. That is known once the
  # frames are, which for a tape is before anything is played.
  def test_two_moments_on_one_frame_with_its_frame_left_out_are_refused
    twice = RubyGBA.playthrough "one frame, two names" do
      wait frames: 10
      moment :here
      moment :and_here
      wait frames: 10
    end
    tape = twice.play(walker).tape
    err = assert_raises(ArgumentError) { tape.compare(nil, nil, ignoring_frames: [:here...:and_here]) }

    assert_match(/no frame/, err.message)
    assert_match(/frame 10/, err.message)
    refute tape.compare(walker, walker, ignoring_frames: [:here..:and_here]).drift?, "with two dots it is that one frame"
  end

  # A range with no ends at all is every frame, and a comparison that looks at none finds
  # nothing — so it is taken for the mistake it is.
  def test_a_range_with_no_ends_is_refused
    err = assert_raises(ArgumentError) { waiting.compare(nil, nil, ignoring_frames: [(nil..nil)]) }

    assert_match(/ignoring_frames/, err.message)
  end

  # `moments:` is not a setting. A comparison is told its moments by the script or the tape
  # it is made from, and a caller's own list must not be able to stand in for them.
  def test_the_moments_cannot_be_given_as_a_setting
    err = assert_raises(ArgumentError) { walk_right.compare(nil, nil, moments: [:ghost], ignoring_frames: [(:ghost..)]) }

    assert_match(/no setting named :moments/, err.message)
    assert_match(/ignoring_frames/, err.message, "the settings there are")
  end

  # A stretch is a range of whole frame numbers or of moment names, in a list. The commonest
  # slip is one range written with no list around it.
  def test_a_stretch_that_is_not_a_range_is_refused_with_how_to_write_one
    [1..120, [5], [[1, 5]], ["1..5"], [1.5..3.0], [:standing], nil].each do |wrong|
      err = assert_raises(ArgumentError) { walk_right.compare(nil, nil, ignoring_frames: wrong) }

      assert_match(/ignoring_frames/, err.message)
      assert_match(/\[1\.\.120, :title\.\.:in_the_world\]/, err.message, "it shows some written out")
    end
  end
end
