# frozen_string_literal: true

require "test_helper"
require "stringio"
require RubyGBA.root.join("examples/hero").to_s

# A PLAYTHROUGH: a game driven with nobody at the controls, from a script that says what to
# press. The script is a list of steps — tap, hold, wait, name a moment — and playing it on a
# cartridge gives back how many frames went by and the frame each named moment fell on.
#
# Every test here builds a cartridge, plays it in the emulator, and asks what a player would
# see: what a variable came to, where a moment fell. None asks how a script is kept.
class TestPlaythrough < Minitest::Test
  runs_on :reference

  # A game that counts what happens to it. It goes round its loop once a frame, and each time:
  # one more tick; one more tap if A was pressed (the press, not the hold); two pixels across
  # if RIGHT is down; and one more if B and LEFT are down together. It does so little that it
  # never takes longer than a frame, so a frame and a trip round its loop are the same thing.
  private def counting_game
    RubyGBA.build("COUNTING", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      ticks = var :ticks, 0
      taps = var :taps, 0
      x = var :x, 0
      both = var :both, 0
      game_loop do
        ticks.add! 1
        pressed(:a).then { taps.add! 1 }
        held(:right).then { x.add! 2 }
        (held(:b) & held(:left)).then { both.add! 1 }
      end
    end
  end

  # A hold keeps a button down for the frames it says, and the result says how long the whole
  # thing took and where the moment fell. RIGHT is down for 20 frames at two pixels a frame, so
  # x is 40 on the frame the hold ends, and stays there once the button is up.
  def test_a_hold_keeps_a_button_down_for_the_frames_it_says
    walk = RubyGBA.playthrough "walk right" do
      wait frames: 10
      hold :right, frames: 20
      moment :walked
      wait frames: 5
    end
    at_the_moment = nil
    played = walk.play(counting_game) { |name, game| at_the_moment = game.var(:x) if name == :walked }

    assert_equal 35, played.frames
    assert_equal({ walked: 30 }, played.moments)
    assert_equal 40, at_the_moment
    assert_equal 40, played.game.var(:x)
  end

  # THE FRAMES A SCRIPT COUNTS ARE FRAMES THE CONSOLE PLAYED, and the game is the witness: it
  # ticks once a frame, so between two moments it has ticked once for every frame the script
  # says went by — and through a wait nothing else about it has moved.
  def test_a_wait_plays_that_many_frames_with_nothing_pressed
    waiting = RubyGBA.playthrough "wait" do
      wait frames: 10
      moment :before
      wait frames: 25
      moment :after
    end
    seen = {}
    waiting.play(counting_game) { |name, game| seen[name] = %i[ticks taps x both].map { |var| game.var(var) } }

    assert_equal 25, seen[:after][0] - seen[:before][0], "the game went round its loop 25 more times"
    assert_equal [0, 0, 0], seen[:after].drop(1), "and no button was down for any of them"
  end

  # A button named twice in one step is that button, once.
  def test_a_button_named_twice_is_held_once
    walk = RubyGBA.playthrough "right, right" do
      wait frames: 10
      hold :right, :right, frames: 5
      wait frames: 2
    end

    assert_equal 10, walk.play(counting_game).game.var(:x)
  end

  # A PRESS BEFORE THE GAME HAS STARTED IS NOT SEEN, on a console as here: a cartridge spends
  # its first frame or more setting itself up, and what was pressed then is deliberately
  # forgotten so that a button held through power-on is not taken as a press. A script that
  # opens with a tap opens with a wait first.
  def test_a_tap_on_the_very_first_frame_is_not_seen_and_one_after_a_wait_is
    at_once = RubyGBA.playthrough "tap at once" do
      press :a
      wait frames: 10
    end
    after_a_wait = RubyGBA.playthrough "wait, then tap" do
      wait frames: 10
      press :a
      wait frames: 10
    end

    assert_equal 0, at_once.play(counting_game).game.var(:taps)
    assert_equal 1, after_a_wait.play(counting_game).game.var(:taps)
  end

  # A TAP IS ONE PRESS. The game counts the press and not the hold, so a button left down
  # would count once however long it stayed there. A tap lets go again, which is what makes
  # the next tap a press of its own: three taps are three.
  def test_each_tap_is_a_press_of_its_own
    tapping = RubyGBA.playthrough "three taps" do
      wait frames: 10
      press :a
      press :a
      press :a
      wait frames: 5
    end
    played = tapping.play(counting_game)

    assert_equal 3, played.game.var(:taps)
    assert_equal 21, played.frames, "a tap is a frame down and a frame up"
  end

  # Several buttons go down together and come up together.
  def test_a_hold_can_keep_several_buttons_down_at_once
    both = RubyGBA.playthrough "two at once" do
      wait frames: 10
      hold :b, :left, frames: 12
      hold :b, frames: 12
      wait frames: 5
    end

    assert_equal 12, both.play(counting_game).game.var(:both)
  end

  # FRAMES ARE COUNTED FROM 1: the first frame played is frame 1, and a moment is the frame
  # that had just been played when the script named it.
  def test_a_moment_is_the_frame_just_played_counted_from_one
    marked = RubyGBA.playthrough "marks" do
      wait frames: 1
      moment :first
      press :a
      moment :after_a_tap
      hold :right, frames: 7
      moment :after_a_hold
    end

    assert_equal({ first: 1, after_a_tap: 3, after_a_hold: 10 }, marked.play(counting_game).moments)
  end

  # --- what a script cannot say, each caught where the playthrough is declared ---

  def test_two_moments_with_one_name_are_refused
    err = assert_raises(ArgumentError) do
      RubyGBA.playthrough "twice" do
        wait frames: 1
        moment :here
        wait frames: 1
        moment :here
      end
    end

    assert_match(/:here/, err.message)
    assert_match(/twice/, err.message)
  end

  def test_a_button_the_console_does_not_have_is_refused_with_the_ones_it_has
    err = assert_raises(ArgumentError) { RubyGBA.playthrough("typo") { press :x } }

    assert_match(/:x/, err.message)
    assert_match(/:a, :b, :select, :start/, err.message)
  end

  def test_a_hold_with_no_button_is_refused_and_points_at_wait
    err = assert_raises(ArgumentError) { RubyGBA.playthrough("nothing held") { hold frames: 4 } }

    assert_match(/no button/, err.message)
    assert_match(/wait/, err.message)
  end

  def test_a_count_of_frames_that_is_not_a_whole_number_above_zero_is_refused
    [0, -3, 1.5, "4"].each do |wrong|
      err = assert_raises(ArgumentError) { RubyGBA.playthrough("bad count") { wait frames: wrong } }

      assert_match(/whole number, 1 or more/, err.message)
    end
  end

  # A moment names the frame just played, and before the first step no frame has been.
  def test_a_moment_before_any_frame_is_refused
    err = assert_raises(ArgumentError) { RubyGBA.playthrough("too soon") { moment :start } }

    assert_match(/before any frame/, err.message)
  end

  def test_a_playthrough_with_no_steps_given_is_refused
    err = assert_raises(ArgumentError) { RubyGBA.playthrough("empty") }

    assert_match(/needs a block/, err.message)
  end

  # --- a real game: the hero example, from its file screen out into the world ---

  # Two taps down the list of files and a tap on A pick the third file; a tap on A in the
  # menu that opens starts a new game; holding RIGHT walks the hero.
  private def walk_out_of_the_file_screen
    RubyGBA.playthrough "hero: third file, new game, walk right" do
      wait frames: 10
      press :down
      press :down
      press :a
      wait frames: 4
      moment :file_picked
      press :a
      wait frames: 4
      moment :standing
      hold :right, frames: 20
      wait frames: 4
      moment :walked
    end
  end

  private def hero_cartridge = Hero.build_rom(out: StringIO.new, err: StringIO.new, profile: false)

  # A menu reads the press and not the hold, so each tap moves the cursor one row and no
  # more: two taps down from the first file are the third. The walk is two pixels for each of
  # the twenty frames RIGHT is down.
  def test_a_script_takes_a_real_game_from_its_menu_into_play
    seen = {}
    screen = {}
    walk_out_of_the_file_screen.play(hero_cartridge) do |moment, game|
      seen[moment] = %i[slot choosing px steps].map { |name| game.var(name) }
      screen[moment] = game.var(:mode)
    end

    # the file picked, whether the second menu opened, how far across the hero is, steps walked
    assert_equal [2, 1, Hero::START_X, 0], seen[:file_picked]
    assert_equal [2, 1, Hero::START_X, 0], seen[:standing]
    assert_equal [2, 1, Hero::START_X + 40, 20], seen[:walked]
    refute_equal screen[:file_picked], screen[:standing], "the second tap on A left the file screen"
    assert_equal screen[:standing], screen[:walked]
  end

  # AT A MOMENT THE GAME CAN BE ASKED ANYTHING a test of a running cartridge asks: here the
  # sprite the console is drawing and a pixel of the picture. The file screen hides the hero
  # behind a flat backdrop; out in the world he is drawn and the corner shows scenery.
  def test_a_sprite_and_a_pixel_can_be_read_at_a_moment
    backdrop = Color.rgb(2, 4, 12)
    seen = {}
    walk_out_of_the_file_screen.play(hero_cartridge) do |moment, game|
      seen[moment] = { hero_drawn: game.sprites(:guy).any?, corner: game.pixel_gba(2, 150) }
    end

    assert_equal({ hero_drawn: false, corner: backdrop }, seen[:file_picked])
    assert seen[:standing][:hero_drawn], "the hero is drawn once the game is being played"
    refute_equal backdrop, seen[:standing][:corner], "and the backdrop of the file screen is gone"
  end

  # The same script on the same cartridge is the same game every time, frame for frame.
  def test_the_same_script_twice_gives_the_same_pictures
    cartridge = hero_cartridge
    pictures = Array.new(2) do
      {}.tap { |at| walk_out_of_the_file_screen.play(cartridge) { |moment, game| at[moment] = game.frame_gba } }
    end

    assert_equal %i[file_picked standing walked], pictures[0].keys
    assert_equal pictures[0], pictures[1]
    refute_equal pictures[0][:standing], pictures[0][:walked], "and walking did change the picture"
  end
end
