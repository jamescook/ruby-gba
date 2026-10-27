# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# What the window keeps for a player, and the settings file it is kept in (Live::Settings): the
# desktop build's rules (runtime/rg_window.c, tested by test_native_window.rb), so the one file
# works for both. Keys are named here as SDL names them, by a small table standing in for SDL.
class TestSettings < Minitest::Test
  Settings = VBlank::Live::Settings

  # SDL's names for the keys these tests use, by scancode.
  NAMES = { 4 => "A", 16 => "M", 17 => "N", 19 => "P", 20 => "Q", 22 => "S", 27 => "X", 29 => "Z", 40 => "Return",
            41 => "Escape", 42 => "Backspace", 43 => "Tab", 44 => "Space", 54 => ",", 58 => "F1", 60 => "F3",
            68 => "F11", 79 => "Right", 80 => "Left", 81 => "Down", 82 => "Up", 229 => "Right Shift" }.freeze

  # Names keys as NAMES does, and finds a key by its name in any case.
  class Names
    def name(key) = NAMES[key]
    def key(name) = NAMES.find { |_, named| named.casecmp?(name) }&.first
  end

  def test_the_settings_start_as_the_desktop_builds
    settings = fresh

    assert_equal VBlank::Live::WindowMenu::STARTING, settings.window
    assert_equal [27], settings.keys_of(:a)
    assert_equal [42, 229], settings.keys_of(:select)
    assert_equal :east, settings.pad_of(:a)
    assert_equal 19, settings.hotkey_of(:pause)
  end

  def test_the_settings_are_written_as_lines_a_player_can_read
    settings = fresh
    settings.window = settings.window.with(scale: 4, volume: 60)
    text = settings.text

    assert_includes text, "scale = 4\n"
    assert_includes text, "volume = 60\n"
    assert_includes text, "key.select = Backspace\nkey.select = Right Shift\n"
    assert_includes text, "pad.a = east\n"
    assert_includes text, "hotkey.pause = P\n"
    assert_includes text, "frame_rate = on\n"
  end

  def test_what_is_written_is_read_back_the_same
    settings = fresh
    settings.window = settings.window.with(scale: 6, volume: 30, muted: true)
    settings.read("key.a = Q\npad.a = west\nhotkey.pause = Space\n")
    written = settings.text
    again = fresh

    assert_empty again.read(written)
    assert_equal written, again.text
  end

  def test_a_line_names_one_setting_and_leaves_the_others_as_they_were
    settings = fresh
    settings.window = settings.window.with(volume: 40)

    assert_empty settings.read("scale = 5\n")
    assert_equal [40, 5], [settings.window.volume, settings.window.scale]
  end

  def test_notes_and_blank_lines_and_any_spacing_and_case_are_fine
    settings = fresh

    assert_empty settings.read("# a note\n\n   SCALE   =   2   \nFullscreen = YES\nmute = 1\n")
    assert_equal [2, true, true], [settings.window.scale, settings.window.fullscreen, settings.window.muted]
  end

  def test_a_key_line_names_the_key_as_sdl_does_in_any_case_and_none_for_no_key
    settings = fresh

    assert_empty settings.read("key.a = q\nkey.b = none\n")
    assert_equal [[20], []], [settings.keys_of(:a), settings.keys_of(:b)]
  end

  def test_a_buttons_first_line_replaces_its_keys_and_each_after_it_adds_one
    settings = fresh
    settings.read("key.select = Q\nkey.select = Space\n")

    assert_equal [20, 44], settings.keys_of(:select)
  end

  def test_a_third_key_for_a_button_is_left_out_and_said
    settings = fresh
    problems = settings.read("key.a = Q\nkey.a = Space\nkey.a = Tab\n")

    assert_equal 1, problems.size
    assert_match(/\ALine 3: A has room for 2 keys/, problems.first)
    assert_equal [20, 44], settings.keys_of(:a)
  end

  def test_a_line_that_cannot_be_used_is_said_in_plain_words_and_the_rest_are_used
    settings = fresh
    problems = settings.read("scale = 99\nvolume = loud\nfullscreen = maybe\nkey.zz = Q\nkey.a = Nonesuch\npad.a = nowhere\n" \
                             "hotkey.nothing = Q\nbogus = 1\nno equals sign\nscale = 2\n")

    assert_equal 9, problems.size
    [/\ALine 1: scale is a whole number from 1 to 10/, /\ALine 2: volume is a whole number from 0 to 100/,
     /\ALine 3: fullscreen is on or off/, /\ALine 4: there is no button called "zz"/, /\ALine 5: "Nonesuch" is not a key's name/,
     /\ALine 6: "nowhere" is not a gamepad button/, /\ALine 7: there is no hotkey called "nothing"/,
     /\ALine 8: there is no setting called "bogus"/, /\ALine 9: "no equals sign" is not `name = value`/].each_with_index do |phrase, i|
      assert_match phrase, problems[i]
    end
    assert_equal [2, [27], :east], [settings.window.scale, settings.keys_of(:a), settings.pad_of(:a)]
  end

  def test_a_key_used_twice_stays_with_the_earlier_and_the_later_loses_it_and_it_is_said
    settings = fresh
    problems = settings.read("hotkey.pause = Z\n")

    assert_equal 1, problems.size
    assert_match(/\AZ is used for both B and Pause/, problems.first)
    assert_nil settings.hotkey_of(:pause)
    assert_equal [29], settings.keys_of(:b)
  end

  def test_two_buttons_that_swap_keys_in_one_file_are_not_a_clash
    settings = fresh

    assert_empty settings.read("key.a = Z\nkey.b = X\n")
    assert_equal [[29], [27]], [settings.keys_of(:a), settings.keys_of(:b)]
  end

  def test_escape_in_a_file_is_refused_since_it_gives_up_choosing_a_key
    settings = fresh
    problems = settings.read("key.a = Escape\n")

    assert_match(/\AEscape gives up choosing a key, so A cannot use it/, problems.first)
    assert_empty settings.keys_of(:a)
  end

  # Bytes that are no letters at all are a line it cannot use, and the rest are used: a file never
  # stops the window opening.
  def test_a_file_that_is_not_text_is_said_and_the_rest_used
    settings = fresh
    problems = settings.read("\xFF\xFE = 1\nscale = 2\n") # as a file read as UTF-8 holds them

    assert_equal 1, problems.size
    assert_equal 2, settings.window.scale
  end

  # A whole number is digits, as the desktop build reads one: 1_0 is not ten.
  def test_a_number_is_digits_only
    settings = fresh

    assert_match(/scale is a whole number/, settings.read("scale = 1_0\n").first)
    assert_equal 3, settings.window.scale
  end

  def test_a_line_too_long_to_be_a_setting_is_said_and_skipped
    settings = fresh
    problems = settings.read("#{'x' * 300}\nscale = 2\n")

    assert_match(/\ALine 1: that line is too long/, problems.first)
    assert_equal 2, settings.window.scale
  end

  # A game's own file is read over the one every game shares, and keeps only what it says itself
  # and what was changed while it played.
  def test_a_games_file_keeps_only_its_own_settings_and_what_changed
    settings = fresh
    settings.read("scale = 4\nfast_forward_speed = 6\nvolume = 70\n")
    settings.mark_inherited
    settings.read("scale = 5\n")
    settings.window = settings.window.with(muted: true)
    text = settings.text(own_only: true)

    assert_includes text, "scale = 5\n"
    assert_includes text, "mute = on\n"
    refute_match(/^volume|^fast_forward_speed|^key\.|^pad\.|^hotkey\./, text)
  end

  def test_a_key_a_games_file_takes_from_a_shared_hotkey_is_written_as_taken
    settings = fresh
    settings.read("hotkey.pause = Q\n")
    settings.mark_inherited

    assert_equal 1, settings.read("key.a = Q\n").size
    assert_includes settings.text(own_only: true), "hotkey.pause = none\n"
  end

  # The window writes only when something changed, and a change to the same value is none.
  def test_only_a_change_needs_writing
    settings = fresh
    refute settings.unwritten?

    settings.window = settings.window
    refute settings.unwritten?

    settings.window = settings.window.with(volume: 50)
    assert settings.unwritten?
    settings.mark_written
    refute settings.unwritten?
  end

  # What a key does, as the window asks it: a console button, or one of the window's own.
  def test_a_keys_button_or_hotkey_is_found_from_the_key
    settings = fresh

    assert_equal :a, settings.button_of_key(27)
    assert_equal :pause, settings.hotkey_of_key(19)
    assert_nil settings.button_of_key(19)
  end

  private

  def fresh = Settings.new(key_names: Names.new)
end
