# frozen_string_literal: true

require "test_helper"
require "stringio"
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
  # A white box on a coloured ground. The box walks +speed+ pixels a frame while RIGHT is
  # down, and the ground turns red once the game has ticked +turns_red_at+ times. It also
  # counts its paces, +counts_by+ for each frame it walks: a number a script can watch that
  # the picture does not show.
  private def walker(speed: 2, turns_red_at: 100_000, counts_by: 1)
    RubyGBA.build("WALKER", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      ticks = var :ticks, 0
      x = var :x, 20
      paces = var :paces, 0
      game_loop do
        ticks.add! 1
        held(:right).then do
          x.add! speed
          paces.add! counts_by
        end
        (ticks >= turns_red_at).then { clear_screen :red }.else { clear_screen :blue }
        draw_rect_at x, 60, 8, 8, :white
      end
    end
  end

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

  private def walk_right
    RubyGBA.playthrough "wait, then walk right" do
      wait frames: 10
      moment :standing
      hold :right, frames: 20
      moment :walked
      wait frames: 30
    end
  end

  # A CARTRIDGE PLAYED ON ITS OWN, a frame at a time, with the buttons a tape says — the long
  # way round, with no comparison in it. The block is handed the running cartridge after
  # each frame and the number of that frame, counted from 1.
  private def each_frame_of(cartridge, tape)
    game = RubyGBA::Diagnostics::Verifier.new(cartridge, frames: 0, vars: cartridge.var_addresses)
    tape.steps.flat_map { |step| [step] * step.frames }.each.with_index(1) do |step, frame|
      yield game.step(1, keys: RubyGBA::Diagnostics::Playthrough.key_mask(step.buttons)), frame
    end
  end

  # The first frame something is true of a cartridge while a tape is played on it.
  private def first_frame(cartridge, tape)
    each_frame_of(cartridge, tape) { |game, frame| return frame if yield(game) }
    nil
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
