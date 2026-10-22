# frozen_string_literal: true

require "test_helper"

# WHAT A PLAYER DOES TO THE WINDOW, tested with no window (runtime/rg_window.c): pause and step,
# fast forward, window size and fullscreen, volume and mute, which key and gamepad button is each
# console button, the hotkeys, and the settings file's text. The menu draws these and calls these,
# and a hotkey calls the same function its menu item does, so this is where they are proved.
#
# The C is driven through a small program (window_harness.c), a command to a line, at both of
# the settings the backend is built at, which have to agree.
class TestNativeWindow < Minitest::Test
  Zig = RubyGBA::IR::Backends::Native::Zig
  HARNESS = Ractor.make_shareable(File.expand_path("window_harness.c", __dir__))

  # --- pause and step ---

  def test_a_pause_stops_the_game_and_a_resume_starts_it_again
    assert_equal %w[0 1 0], ask("paused", "pause", "paused", "resume", "paused")
  end

  def test_the_pause_hotkey_pauses_and_the_same_key_resumes
    assert_equal %w[1 0], ask("hotkey pause 1", "paused", "hotkey pause 0", "hotkey pause 1", "paused")
  end

  def test_a_step_runs_one_frame_while_paused_and_no_more
    assert_equal %w[1 0], ask("pause", "step", "take_step", "take_step")
  end

  def test_two_steps_asked_for_before_the_window_looks_are_one
    assert_equal %w[1 0], ask("pause", "step", "step", "take_step", "take_step")
  end

  def test_a_step_asked_for_when_not_paused_is_not_kept_for_later
    assert_equal %w[0], ask("step", "pause", "take_step")
  end

  def test_a_resume_cancels_a_step_that_was_owed
    assert_equal %w[0], ask("pause", "step", "resume", "pause", "take_step")
  end

  # --- fast forward ---

  def test_fast_forward_is_held_and_four_times_to_begin_with
    assert_equal %w[4 1 0], ask("fast_speed", "hotkey fast_forward 1", "fast_forwarding", "hotkey fast_forward 0", "fast_forwarding").values_at(0, 1, 2)
  end

  def test_a_paused_game_does_not_fast_forward
    assert_equal %w[0], ask("hotkey fast_forward 1", "pause", "fast_forwarding")
  end

  def test_fast_forwards_speed_is_two_to_eight_times
    assert_equal %w[8 2 5], ask("set_fast_speed 100", "fast_speed", "set_fast_speed -3", "fast_speed", "set_fast_speed 5", "fast_speed")
  end

  # --- window size and fullscreen ---

  def test_the_window_starts_at_three_times_and_the_scale_is_a_whole_number_from_one_to_ten
    assert_equal %w[3 7 10 1], ask("scale", "set_scale 7", "scale", "set_scale 99", "scale", "set_scale 0", "scale").values_at(0, 1, 2, 3)
  end

  def test_choosing_a_size_asks_the_window_to_change_it_once
    assert_equal %w[2 0], ask("set_scale 5", "set_scale 5", "take_changes", "take_changes")
  end

  def test_the_size_it_already_is_needs_nothing_done
    assert_equal %w[0], ask("set_scale 3", "take_changes")
  end

  def test_dragging_the_window_sets_the_scale_to_the_whole_number_of_times_the_picture_fits
    assert_equal %w[4 2 1], [ask("size_changed 975 700", "scale"), ask("size_changed 1000 330", "scale"), ask("size_changed 100 100", "scale")].flatten
  end

  def test_dragging_asks_nothing_of_the_window_since_the_player_did_it
    assert_equal %w[0], ask("size_changed 960 640", "take_changes")
  end

  def test_fullscreen_is_asked_for_by_its_hotkey_and_the_same_hotkey_ends_it
    assert_equal %w[1 1 0 1], ask("hotkey fullscreen 1", "fullscreen", "take_changes", "hotkey fullscreen 1", "fullscreen", "take_changes")
  end

  def test_the_function_the_menu_calls_does_what_the_hotkey_does
    assert_equal ask("hotkey fullscreen 1", "fullscreen", "take_changes"), ask("toggle_fullscreen", "fullscreen", "take_changes")
    assert_equal ask("hotkey mute 1", "muted", "gain"), ask("toggle_mute", "muted", "gain")
    assert_equal ask("hotkey frame_rate 1", "frame_rate_shown"), ask("toggle_frame_rate", "frame_rate_shown")
  end

  def test_a_window_made_fullscreen_by_the_system_is_remembered_without_being_asked_to_change
    assert_equal %w[1 0], ask("fullscreen_happened 1", "fullscreen", "take_changes")
  end

  def test_a_fullscreen_windows_size_is_not_the_players_choice
    assert_equal %w[3], ask("set_fullscreen 1", "size_changed 1920 1080", "scale")
  end

  # --- volume and mute ---

  def test_volume_starts_at_a_hundred_and_stays_from_nought_to_a_hundred
    assert_equal %w[100 100 0], ask("volume", "set_volume 500", "volume", "set_volume -4", "volume")
  end

  def test_a_hundred_lets_the_sound_through_untouched
    assert_equal ["65536", "32767 -32768 5 0"], ask("gain", "apply_volume 32767 -32768 5 0").map(&:strip)
  end

  # Half the slider is a quarter of the amplitude, which sounds about half as loud; 0 is silence.
  def test_the_volume_is_the_square_of_the_slider_on_the_samples
    assert_equal ["8191 -8192 1 0"], ask("set_volume 50", "apply_volume 32767 -32768 5 0").map(&:strip)
    assert_equal ["327 -327 0 0"], ask("set_volume 10", "apply_volume 32767 -32768 5 0").map(&:strip)
    assert_equal ["0 0"], ask("set_volume 0", "apply_volume 32767 -32768").map(&:strip)
  end

  def test_mute_silences_the_sound_and_keeps_the_volume_for_when_it_is_let_go
    out = ask("set_volume 60", "hotkey mute 1", "apply_volume 1000 -1000", "volume", "muted", "hotkey mute 1", "muted", "gain")

    assert_equal ["0 0", "60", "1", "0", "23592"], out.map(&:strip)
  end

  # --- the frame rate ---

  def test_the_frame_rate_shows_to_begin_with_and_the_hotkey_hides_and_shows_it
    assert_equal %w[1 0 1], ask("frame_rate_shown", "hotkey frame_rate 1", "frame_rate_shown", "hotkey frame_rate 0", "hotkey frame_rate 1", "frame_rate_shown")
  end

  def test_the_frame_rate_is_the_frames_played_a_second_over_the_last_half_second
    frames = (0..90).map { |i| "frame_played #{1_000_000_000 + (i * 16_666_667)}" }
    out = ask("frames_a_second 1000000000", *frames, "frames_a_second 2500000000")

    assert_in_delta 60.0, out.last.to_f, 1.0
  end

  def test_a_window_does_not_say_nothing_for_its_first_half_second
    frames = (0..20).map { |i| "frame_played #{1_000_000_000 + (i * 16_666_667)}" }
    out = ask(*frames, "frames_a_second #{1_000_000_000 + (20 * 16_666_667)}")

    assert_in_delta 60.0, out.last.to_f, 1.0
  end

  def test_a_game_that_has_stopped_has_a_frame_rate_of_nothing
    out = ask("frame_played 1000000000", "frames_a_second 1000000000", "frames_a_second 1600000000", "frames_a_second 2200000000")

    assert_equal 0.0, out.last.to_f
  end

  # --- keys and gamepad buttons ---

  def test_the_keys_start_as_mgbas_and_a_keys_owner_is_found_from_the_key
    assert_equal ["button a", "button select", "button select", "hotkey pause", "none"],
                 ask("owner X", "owner Backspace", "owner Right_Shift", "owner P", "owner Q")
  end

  def test_a_button_has_two_keys_and_either_is_the_button
    assert_equal ["Backspace Right Shift"], ask("keys_of select")
  end

  def test_a_key_another_button_has_is_refused_in_plain_words_and_nothing_changes
    out = ask("bind_key a 1 Z", "keys_of a", "keys_of b")

    assert_equal "Z is already the B button. Clear it there first, then it can be used here.", out[0]
    assert_equal ["X none", "Z none"], out[1..2]
  end

  def test_a_key_a_hotkey_has_is_refused_saying_which_hotkey
    assert_equal ["P is the hotkey for \"Pause\". Change that hotkey first, then this key can be used here.", "X none"],
                 ask("bind_key a 1 P", "keys_of a")
  end

  def test_a_hotkey_cannot_take_a_console_buttons_key_or_another_hotkeys
    out = ask("bind_hotkey pause X", "bind_hotkey pause M", "hotkey_of pause")

    assert_equal "X is already the A button. Clear it there first, then it can be used here.", out[0]
    assert_match(/\AM is the hotkey for "Mute"/, out[1])
    assert_equal "P", out[2]
  end

  def test_a_key_given_to_the_other_place_of_its_own_button_moves_there
    assert_equal ["ok", "none X"], ask("bind_key a 1 X", "keys_of a")
    assert_equal ["ok", "X none"], ask("bind_key a 0 X", "keys_of a")
  end

  def test_a_key_is_cleared_with_none_and_a_cleared_key_can_be_used_elsewhere
    assert_equal ["ok", "none none", "ok", "button b"], ask("bind_key a 0 none", "keys_of a", "bind_key b 1 X", "owner X")
  end

  def test_escape_cannot_be_a_key_because_it_gives_up_choosing_one
    assert_match(/Escape gives up/, ask("bind_key a 1 Escape").first)
    assert_match(/Escape gives up/, ask("bind_hotkey pause Escape").first)
  end

  def test_the_keys_are_put_back_as_they_were
    assert_equal ["ok", "ok", "Backspace Right Shift", "X none"], ask("bind_key select 1 none", "bind_key a 0 Q", "reset_keys", "keys_of select", "keys_of a")
  end

  def test_putting_the_keys_back_takes_one_from_a_hotkey_that_has_since_been_given_it_and_says_so
    out = ask("bind_key a 0 Q", "bind_hotkey pause X", "reset_keys", "hotkey_of pause", "keys_of a", "notice")

    assert_equal ["none", "X none"], out[2, 2]
    assert_match(/X is used for both A and Pause/, out[4])
  end

  def test_a_gamepad_button_starts_where_the_console_has_it
    assert_equal %w[east south], ask("pad_of a", "pad_of b")
  end

  def test_a_gamepad_button_taken_by_another_swaps_with_it
    assert_equal %w[ok south east], ask("bind_pad a south", "pad_of a", "pad_of b")
  end

  def test_a_gamepad_button_nobody_has_is_taken_without_a_swap
    assert_equal %w[ok west south], ask("bind_pad a west", "pad_of a", "pad_of b")
  end

  def test_the_gamepad_is_put_back_as_it_was
    assert_equal %w[ok east south], ask("bind_pad a south", "reset_pad", "pad_of a", "pad_of b")
  end

  def test_a_hotkeys_key_is_chosen_and_the_old_one_is_free
    assert_equal ["ok", "Q", "hotkey pause", "none"], ask("bind_hotkey pause Q", "hotkey_of pause", "owner Q", "owner P")
  end

  def test_the_hotkeys_are_put_back_as_they_were
    assert_equal %w[ok P], ask("bind_hotkey pause Q", "reset_hotkeys", "hotkey_of pause")
  end

  def test_no_hotkey_starts_on_a_key_a_console_button_has
    hotkeys = %w[pause step frame_rate fullscreen mute menu fast_forward]
    keys = ask(*hotkeys.map { |hotkey| "hotkey_of #{hotkey}" })

    assert_equal hotkeys.size, keys.uniq.size, "each hotkey has a key of its own"
    owners = ask(*keys.map { |key| "owner #{key.tr(' ', '_')}" })
    assert_equal(hotkeys.map { |hotkey| "hotkey #{hotkey}" }, owners)
  end

  # --- choosing a key by pressing it ---

  def test_the_next_key_pressed_is_taken_for_the_button_being_chosen
    out = ask("capture_key a 1", "capturing", "press Q", "capturing", "keys_of a")

    assert_equal "1 [Press a key for A (Escape to give up)...]", out[0]
    assert_equal "1 []", out[1]
    assert_equal "0 []", out[2]
    assert_equal "X Q", out[3]
  end

  def test_the_next_key_pressed_is_taken_for_the_hotkey_being_chosen
    out = ask("capture_hotkey mute", "capturing", "press Q", "hotkey_of mute")

    assert_equal "1 [Press a key for \"Mute\" (Escape to give up)...]", out[0]
    assert_equal ["1 []", "Q"], out[1..2]
  end

  def test_a_key_pressed_when_nothing_is_being_chosen_is_not_taken
    assert_equal ["0 []"], ask("press Q")
  end

  def test_a_refused_key_is_said_and_the_window_goes_on_waiting_for_another
    out = ask("capture_key a 1", "press Z", "capturing", "press Q", "capturing", "keys_of a")

    assert_equal "1 [Z is already the B button. Clear it there first, then it can be used here.]", out[0]
    assert_equal "1 [Press a key for A (Escape to give up)...]", out[1]
    assert_equal ["1 []", "0 []", "X Q"], out[2..4]
  end

  def test_escape_gives_up_choosing_and_leaves_the_key_alone
    assert_equal ["1 []", "0 []", "X none"], ask("capture_key a 0", "press Escape", "capturing", "keys_of a")
  end

  def test_a_gamepad_button_pressed_is_taken_for_the_button_being_chosen
    out = ask("capture_pad b", "capturing", "press_pad north", "pad_of b", "press_pad west")

    assert_equal "1 [Press a gamepad button for B...]", out[0]
    assert_equal %w[1 north 0], out[1..3]
  end

  def test_a_key_is_not_taken_by_a_wait_for_a_gamepad_button
    assert_equal ["0 []"], ask("capture_pad b", "press Q")
  end

  # --- the settings file ---

  def test_the_settings_are_written_as_lines_a_player_can_read
    text = ask("set_scale 4", "set_volume 60", "write").join("\n")

    assert_includes text, "scale = 4\n"
    assert_includes text, "volume = 60\n"
    assert_includes text, "key.select = Backspace\nkey.select = Right Shift\n"
    assert_includes text, "pad.a = east\n"
    assert_includes text, "hotkey.pause = P\n"
    assert_includes text, "frame_rate = on\n"
  end

  def test_what_is_written_is_read_back_the_same
    changes = ["set_scale 6", "set_volume 33", "set_mute 1", "bind_key a 1 Q", "bind_pad a west", "bind_hotkey pause Space"]
    written = ask(*changes, "write").reject { |line| line == "ok" }.join("\n").sub(/\n--- \d+\z/, "\n")
    out = ask("read\n#{written}.", "write")

    assert_equal "0 problems", out.first
    assert_equal written, out.drop(1).join("\n").sub(/\n--- \d+\z/, "\n")
  end

  def test_a_line_names_one_setting_and_leaves_the_others_as_they_were
    assert_equal ["0 problems", "40", "5"], ask("set_volume 40", "read\nscale = 5\n.", "volume", "scale")
  end

  def test_notes_and_blank_lines_and_any_spacing_and_case_are_fine
    out = ask("read\n# a note\n\n   SCALE   =   2   \nFullscreen = YES\nmute = 1\n.", "scale", "fullscreen", "muted")

    assert_equal ["0 problems", "2", "1", "1"], out
  end

  def test_a_key_line_names_the_key_as_sdl_does_in_any_case_and_none_for_no_key
    assert_equal ["0 problems", "Q none", "none none"], ask("read\nkey.a = q\nkey.b = none\n.", "keys_of a", "keys_of b")
  end

  def test_a_buttons_first_line_replaces_its_keys_and_each_after_it_adds_one
    assert_equal ["0 problems", "Q Space"], ask("read\nkey.select = Q\nkey.select = Space\n.", "keys_of select")
  end

  def test_a_third_key_for_a_button_is_left_out_and_said
    out = ask("read\nkey.a = Q\nkey.a = Space\nkey.a = Tab\n.", "keys_of a")

    assert_equal ["1 problems", "Line 3: A has room for 2 keys, so \"Tab\" is left out.", "Q Space"], out
  end

  def test_a_comma_is_a_key_and_not_a_separator
    assert_equal ["0 problems", ", none"], ask("read\nkey.a = ,\n.", "keys_of a")
  end

  def test_a_line_that_cannot_be_used_is_said_in_plain_words_and_the_rest_are_used
    file = "scale = 99\nvolume = loud\nfullscreen = maybe\nkey.zz = Q\nkey.a = Nonesuch\npad.a = nowhere\nhotkey.nothing = Q\nbogus = 1\nno equals sign\nscale = 2\n"
    out = ask("read\n#{file}.", "scale", "keys_of a", "pad_of a")

    assert_equal "9 problems", out.first
    assert_equal ["Line 1: scale is a whole number from 1 to 10, not \"99\".",
                  "Line 2: volume is a whole number from 0 to 100, not \"loud\".",
                  "Line 3: fullscreen is on or off, not \"maybe\".",
                  "Line 4: there is no button called \"zz\" (they are a, b, select, start, right, left, up, down, r, l).",
                  "Line 5: \"Nonesuch\" is not a key's name, so A keeps the key it had.",
                  "Line 6: \"nowhere\" is not a gamepad button the window knows, so A keeps the one it had.",
                  "Line 7: there is no hotkey called \"nothing\".",
                  "Line 8: there is no setting called \"bogus\", so the line is left out.",
                  "Line 9: \"no equals sign\" is not `name = value`, so it is left out."], out[1..9]
    assert_equal ["2", "X none", "east"], out.last(3), "the line after the bad ones was still used"
  end

  def test_a_key_used_twice_stays_with_the_earlier_and_the_later_loses_it_and_it_is_said
    out = ask("read\nhotkey.pause = Z\n.", "hotkey_of pause", "keys_of b")

    assert_equal ["1 problems", "Z is used for both B and Pause. It stays with B and is taken off Pause.", "none", "Z none"], out
  end

  def test_two_buttons_that_swap_keys_in_one_file_are_not_a_clash
    assert_equal ["0 problems", "Z none", "X none"], ask("read\nkey.a = Z\nkey.b = X\n.", "keys_of a", "keys_of b")
  end

  def test_escape_in_a_file_is_refused_since_it_gives_up_choosing_a_key
    out = ask("read\nkey.a = Escape\n.", "keys_of a")

    assert_equal ["1 problems", "Escape gives up choosing a key, so A cannot use it and has no key.", "none none"], out
  end

  def test_a_file_that_is_nothing_like_settings_is_all_problems_and_nothing_changes
    out = ask("read\n{\"json\": true}\nwhat is this\n.", "scale", "volume")

    assert_equal ["2 problems", "Line 1: \"{\"json\": true}\" is not `name = value`, so it is left out.",
                  "Line 2: \"what is this\" is not `name = value`, so it is left out.", "3", "100"], out
  end

  def test_a_line_too_long_to_be_a_setting_is_said_and_skipped
    out = ask("read\n#{'x' * 300}\nscale = 2\n.", "scale")

    assert_equal ["1 problems", "Line 1: that line is too long to be a setting, so it is left out.", "2"], out
  end

  def test_text_that_does_not_fit_is_cut_short_and_the_length_it_wanted_is_said
    wanted, kept = ask("write_small").first.split.map(&:to_i)

    assert_operator wanted, :>, 1000
    assert_equal 39, kept
  end

  # --- when the settings are written ---

  def test_nothing_is_due_until_something_changes
    assert_equal %w[0 0], ask("due", "unwritten")
  end

  def test_the_settings_are_due_once_half_a_second_has_gone_by_with_no_change
    out = ask("set_volume 50", *(["due"] * 32), "unwritten")

    assert_equal(["0"] * 30 + %w[1 1 1], out)
  end

  def test_a_change_while_waiting_makes_it_wait_again_so_dragging_a_slider_is_one_write
    out = ask("set_volume 50", *(["due"] * 20), "set_volume 51", *(["due"] * 30), "due")

    assert_equal(["0"] * 50 + ["1"], out)
  end

  def test_once_written_nothing_is_due_until_the_next_change
    out = ask("set_volume 50", *(["due"] * 30), "due", "written", "unwritten", "due")

    assert_equal %w[1 0 0], [out[30], out[31], out[32]]
  end

  def test_a_write_that_failed_is_owed_still_and_tried_again_after_the_same_wait
    out = ask("set_volume 50", *(["due"] * 30), "due", "not_written", *(["due"] * 30), "due", "unwritten")

    assert_equal "1", out[30]
    assert_equal(["0"] * 30 + %w[1 1], out[31..])
  end

  def test_a_setting_set_to_what_it_already_is_is_no_change
    assert_equal %w[0], ask("set_volume 100", "set_mute 0", "set_scale 3", "unwritten")
  end

  # --- the game's variables ---

  def test_the_variables_are_kept_up_to_five_hundred_and_twelve_and_the_rest_counted
    assert_equal ["512 v5 10 88"], ask("watch")
  end

  private

  # What the harness answers to +commands+, a line each, as lines — run at both settings of the
  # backend, which have to agree. A command that prints nothing adds no line.
  def ask(*commands)
    input = commands.map { |command| "#{command}\n" }.join
    checked, fast = %i[checked fast].map do |mode|
      exe = Zig.compile_without_sdl([HARNESS, File.join(Zig::RUNTIME_DIR, "rg_window.c")], mode: mode)
      Zig.run_program(exe, input: input).lines.map(&:chomp)
    end
    assert_equal checked, fast, "the checked and the optimised build should answer alike"
    checked
  end
end
