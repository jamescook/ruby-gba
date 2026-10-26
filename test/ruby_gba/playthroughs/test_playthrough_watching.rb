# frozen_string_literal: true

require "test_helper"
require "stringio"
require "fileutils"
require "png_reading"

# A SCRIPT THAT WATCHES THE GAME. Counting frames is exact, and brittle: the day a screen takes
# a frame longer to come up, every step after it is a frame out. So a script can also wait for
# something to be true of the game — "until the box is up", "until the hero is at the door" —
# and carry on from the frame it first is.
#
# The game under test says how far along it is: it ticks once a frame, and it paints the screen
# red from its tenth tick, blue before.
class TestPlaythroughWatching < Minitest::Test
  include PNGReading

  private def ticking_game
    RubyGBA.build("TICKING", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      ticks = var :ticks, 0
      x = var :x, 0
      game_loop do
        ticks.add! 1
        held(:right).then { x.add! 2 }
        (ticks >= 10).then { clear_screen :red }.else { clear_screen :blue }
      end
    end
  end

  # THE FIRST FRAME IT IS TRUE, and not one after: the game is asked after every frame, and on
  # the frame the answer is first yes the script moves on. The game ticks once a frame, so
  # stopping on the first frame it has ticked 50 times means it reads exactly 50 there.
  def test_a_wait_until_ends_on_the_first_frame_its_condition_holds
    waiting = RubyGBA.playthrough "wait for fifty ticks" do
      wait_until("the game has ticked fifty times") { |game| game.var(:ticks) >= 50 }
      moment :fifty
      wait frames: 5
      moment :later
    end
    ticks = {}
    played = waiting.play(ticking_game) { |name, game| ticks[name] = game.var(:ticks) }

    assert_equal 50, ticks[:fifty]
    assert_equal 55, ticks[:later]
    assert_equal 5, played.moments[:later] - played.moments[:fifty]
    assert_equal played.moments[:later], played.frames
  end

  # WALK UNTIL YOU ARE THERE. The buttons stay down while the game is watched, and come up
  # when the wait ends: RIGHT moves two pixels a frame, so the first frame x is 30 or more it
  # is exactly 30, and it is still 30 five frames after the buttons came up.
  def test_a_hold_until_keeps_the_buttons_down_until_its_condition_holds_and_then_lets_go
    walking = RubyGBA.playthrough "walk to thirty" do
      wait frames: 10
      hold_until("the game has moved thirty pixels across", :right) { |game| game.var(:x) >= 30 }
      moment :there
      wait frames: 5
      moment :later
    end
    across = {}
    played = walking.play(ticking_game) { |name, game| across[name] = game.var(:x) }

    assert_equal({ there: 30, later: 30 }, across)
    assert_equal 25, played.moments[:there], "ten frames of waiting and fifteen of walking"
  end

  # A wait whose answer is already yes still plays a frame: the game is asked after a frame,
  # never before one.
  def test_a_wait_that_is_already_true_plays_one_frame
    at_once = RubyGBA.playthrough "nothing to wait for" do
      wait frames: 20
      wait_until("the game has ticked at all") { |game| game.var(:ticks) >= 1 }
      moment :after
    end

    assert_equal 21, at_once.play(ticking_game).moments[:after]
  end

  # --- a wait that never ends ---

  GaveUp = RubyGBA::Playthroughs::GaveUp

  # A wait for something that never comes, given up on +frame+: the error, with the folder its
  # picture was left in taken away once the block has looked at it.
  private def giving_up_on(frame)
    script = RubyGBA.playthrough "wait for nothing" do
      wait frames: 2
      wait_until("the moon is full", within: frame - 2) { |_game| false }
    end
    error = assert_raises(GaveUp) { script.play(ticking_game) }
    yield error
  ensure
    FileUtils.remove_entry(File.dirname(error.picture)) if error
  end

  # IT STOPS AND SAYS WHICH WAIT, whose script, and on which frame.
  def test_a_wait_that_never_ends_stops_with_its_words_and_its_frame
    giving_up_on(7) do |error|
      assert_equal 7, error.frame, "two frames of waiting, then the five it would wait"
      assert_equal "the moon is full", error.words
      assert_match(/"wait for nothing"/, error.message)
      assert_match(/until the moon is full/, error.message)
      assert_match(/in 5 frames/, error.message)
      assert_match(/frame 7\b/, error.message)
      assert error.message.lines.any? { |line| line.strip == error.picture }, "the picture's path is on a line of its own"
    end
  end

  # ...AND LEAVES A PICTURE OF THE SCREEN AT THAT FRAME, not the one before. The game turns
  # from blue to red as it plays, so the frames either side of the turn tell a picture taken
  # a frame early from one taken on time. What the screen showed on each frame is asked of a
  # second playing that simply counts to it.
  def test_the_picture_a_wait_leaves_is_the_screen_on_the_frame_it_gave_up
    frames = (9..13).to_a
    counting = RubyGBA.playthrough "count" do
      wait frames: frames.first
      moment :"frame_#{frames.first}"
      frames.drop(1).each do |frame|
        wait frames: 1
        moment :"frame_#{frame}"
      end
    end
    shown = {}
    counting.play(ticking_game) { |name, game| shown[name] = game.pixel(0, 0).values_at(:r, :g, :b) }
    left = frames.to_h do |frame|
      [:"frame_#{frame}", giving_up_on(frame) { |error| png_pixel(File.binread(error.picture), 0, 0) }]
    end

    assert_equal shown, left
    assert_equal [[0, 0, 255], [255, 0, 0]], shown.values.uniq.sort, "and those frames span the turn from blue to red"
  end

  # Both steps say how long they will wait, and say nothing for ten seconds of play.
  def test_how_long_a_step_waits_can_be_said_and_is_ten_seconds_when_it_is_not
    said = RubyGBA.playthrough("walk nowhere") { hold_until("the game is somewhere else", :b, within: 12) { |_game| false } }
    unsaid = RubyGBA.playthrough("wait") { wait_until("the moon is full") { |_game| false } }
    errors = [said, unsaid].map { |script| assert_raises(GaveUp) { script.play(ticking_game) } }

    assert_equal [12, 600], errors.map(&:frame)
  ensure
    errors&.each { |error| FileUtils.remove_entry(File.dirname(error.picture)) }
  end

  # A BLOCK THAT ANSWERS A NUMBER IS A SLIP, and a quiet one: in Ruby nought counts as yes, so
  # `flags & 4` would end the wait on its first frame whatever the flags were. The block has
  # to answer yes or no.
  def test_a_block_that_answers_a_number_is_refused_and_told_to_compare
    script = RubyGBA.playthrough "flag" do
      wait_until("the flag is up") { |game| game.var(:ticks) & 4096 }
    end
    err = assert_raises(ArgumentError) { script.play(ticking_game) }

    assert_match(/the flag is up/, err.message)
    assert_match(/answered 0/, err.message)
    assert_match(/true or false/, err.message)
  end

  # --- what a watching step cannot say ---

  def test_a_watching_step_needs_words_a_block_and_a_ceiling_that_counts
    no_words = assert_raises(ArgumentError) { RubyGBA.playthrough("a") { wait_until("") { |_game| true } } }
    no_block = assert_raises(ArgumentError) { RubyGBA.playthrough("b") { wait_until("the box is up") } }
    no_count = assert_raises(ArgumentError) { RubyGBA.playthrough("c") { wait_until("the box is up", within: 0) { true } } }

    assert_match(/a few words/, no_words.message)
    assert_match(/no block/, no_block.message)
    assert_match(/within: must be a whole number/, no_count.message)
  end

  # The words come first and the buttons after. Written the way `hold :right, frames:` is —
  # button first — it is the words that are missing, and the error says so.
  def test_a_hold_until_with_its_button_first_is_told_the_words_come_first
    err = assert_raises(ArgumentError) { RubyGBA.playthrough("swapped") { hold_until(:right, "the door") { true } } }

    assert_match(/a few words/, err.message)
    assert_match(/:right/, err.message)
  end

  # With no button it is a wait, and the wait that watches is `wait_until`.
  def test_a_hold_until_with_no_button_is_pointed_at_wait_until
    err = assert_raises(ArgumentError) { RubyGBA.playthrough("no button") { hold_until("the door") { true } } }

    assert_match(/names no button/, err.message)
    assert_match(/wait_until/, err.message)
  end
end
