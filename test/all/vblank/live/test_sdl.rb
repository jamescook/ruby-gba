# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"

# The window a game is played live in: SDL3, reached through Fiddle. These open it with SDL's
# dummy video driver, which makes windows nobody sees, so they need no screen. A machine without
# SDL3 fails the ones that open a window, saying what to install: the suite needs it as it needs zig.
class TestSDL < Minitest::Test
  # SDL's driver is chosen from the process's settings, and Fiddle calls into C from the main
  # Ractor only.
  runs_on_the_main_ractor!

  SDL = VBlank::Live::SDL
  RATE = 48_000
  FRAME_SAMPLES = 804 # a frame's share of a second at RATE, near enough

  def setup
    @drivers_before = ENV.to_h.slice("SDL_VIDEODRIVER", "SDL_AUDIODRIVER")
    ENV["SDL_VIDEODRIVER"] = "dummy"
    ENV["SDL_AUDIODRIVER"] = "dummy"
  end

  def teardown
    %w[SDL_VIDEODRIVER SDL_AUDIODRIVER].each { |name| ENV[name] = @drivers_before[name] }
  end

  # A frame's sound goes to the speaker as it is, with no silence put in ahead of it: the speaker
  # may still be playing what it took last, and silence put in then is a gap a person hears. The
  # session keeps a few frames waiting itself, and where the speaker does run out, SDL plays silence.
  def test_the_sound_a_window_is_handed_waits_for_the_speaker
    window = open_window
    window.play_sound(Array.new(FRAME_SAMPLES, 1000), RATE)

    assert_operator window.sound_waiting, :>, 0
    assert_operator window.sound_waiting, :<=, FRAME_SAMPLES.fdiv(RATE)
  ensure
    window&.close
  end

  # Before any sound there is no speaker, so the session plays the window on the clock until the
  # first frame's sound opens one.
  def test_a_window_has_no_speaker_until_it_is_handed_sound
    window = open_window

    assert_nil window.sound_waiting
  ensure
    window&.close
  end

  # A game far ahead of the speaker — played uncapped, for measuring — has the sound past a few
  # frames' worth thrown away, rather than heard ever later.
  def test_sound_far_ahead_of_the_speaker_is_not_kept
    window = open_window
    30.times { window.play_sound(Array.new(FRAME_SAMPLES, 1000), RATE) }

    kept = SDL::SOUND_BEHIND_FRAMES + 1 # the frame that takes it past the most is still kept
    assert_operator window.sound_waiting, :>, 0, "the speaker was never opened"
    assert_operator window.sound_waiting, :<=, (kept * FRAME_SAMPLES).fdiv(RATE)
  ensure
    window&.close
  end

  def test_a_window_shows_a_picture_and_holds_no_buttons_until_one_is_pressed
    window = open_window
    window.show(Array.new(240 * 160, 0x001F), 240, 160)

    assert_empty window.held_buttons(1)
    refute window.stop?
  ensure
    window&.close
  end

  # Closing the window, which SDL hears as the last window gone, stops the play once the window
  # has read what it heard.
  def test_closing_the_window_stops_the_play
    window = open_window
    push_event([SDL::EVENT_QUIT].pack("L"))
    window.show(Array.new(240 * 160, 0), 240, 160)

    assert window.stop?
  ensure
    window&.close
  end

  # P pauses, as it does in the desktop build: the window holds, with the sound queued before the
  # pause thrown away, until P is pressed again.
  def test_p_pauses_the_window_until_it_is_pressed_again
    window = open_window
    window.play_sound(Array.new(FRAME_SAMPLES, 1000), RATE)
    press_key(SDL::PAUSE)
    window.show(Array.new(240 * 160, 0), 240, 160)
    press_key(SDL::PAUSE)

    assert window.hold_while_paused
    assert_equal 0, window.sound_waiting
    refute window.hold_while_paused, "the second P should have ended the pause"
  ensure
    window&.close
  end

  # N while paused lets the game play one frame and then holds again, as the desktop build's step
  # does. Not paused, it does nothing. The window closed after the step is read only once the
  # pause holds again, so a step that did not happen ends the play rather than waiting forever.
  def test_n_steps_a_paused_window_one_frame
    window = open_window
    press_key(SDL::STEP)
    press_key(SDL::PAUSE)
    press_key(SDL::STEP)
    window.show(Array.new(240 * 160, 0), 240, 160)
    push_event([SDL::EVENT_QUIT].pack("L"))

    assert window.hold_while_paused
    refute window.stop?, "the step should have let one frame play before the pause held again"
    assert window.hold_while_paused, "the pause should hold again after the step"
    assert window.stop?
  ensure
    window&.close
  end

  # Tab fast forwards for as long as it is held, as it does in the desktop build.
  def test_tab_fast_forwards_while_it_is_held
    window = open_window
    press_key(SDL::FAST_FORWARD)
    window.show(Array.new(240 * 160, 0), 240, 160)
    held = window.fast_forward_speed(1)
    press_key(SDL::FAST_FORWARD, down: false)
    window.show(Array.new(240 * 160, 0), 240, 160)

    assert_equal 4, held
    assert_equal 1, window.fast_forward_speed(1)
  ensure
    window&.close
  end

  # F1 opens the menu, as in the desktop build, and the game is held while it is open: Enter goes
  # into the first heading's lines, and Enter on Resume, the first of them, carries on.
  def test_f1_opens_the_menu_and_holds_the_game_until_resume
    window = open_window
    press_key(SDL::MENU)
    window.show(Array.new(240 * 160, 0), 240, 160)
    2.times { press_key(SDL::MENU_KEYS.key(:enter)) }

    assert window.hold_while_paused
    refute window.hold_while_paused, "Resume should have closed the menu"
  ensure
    window&.close
  end

  # The key above Tab opens it too, which a Mac keyboard presses without fn.
  def test_the_key_above_tab_opens_the_menu
    window = open_window
    press_key(SDL::GRAVE)
    window.show(Array.new(240 * 160, 0), 240, 160)
    press_key(SDL::GRAVE)

    assert window.hold_while_paused
  ensure
    window&.close
  end

  # What the menu changes, the window does: here it is made twice the picture's size and quieter.
  def test_the_menu_changes_the_window
    window = open_window
    window.play_sound(Array.new(FRAME_SAMPLES, 0), RATE)
    press_key(SDL::MENU)
    window.show(Array.new(240 * 160, 0), 240, 160)
    # To Window, into Size, one bigger; back up to the bar, on to Sound, into Volume, one step down.
    %i[right down right up right down left].each { |key| press_key(SDL::MENU_KEYS.key(key)) }
    press_key(SDL::MENU)
    window.hold_while_paused

    assert_equal [480, 320], window.window_size
    assert_in_delta 0.9, window.speaker_volume, 0.001
  ensure
    window&.close
  end

  # Quit in the menu stops the play.
  def test_quit_in_the_menu_stops_the_play
    window = open_window
    press_key(SDL::MENU)
    window.show(Array.new(240 * 160, 0), 240, 160)
    3.times { press_key(SDL::MENU_KEYS.key(:down)) }
    press_key(SDL::MENU_KEYS.key(:enter))
    window.hold_while_paused

    assert window.stop?
  ensure
    window&.close
  end

  # A gamepad works the menu: Back and Start pressed together open it, the D-pad moves, A does what
  # a line says. Here: into Game's lines, and Resume.
  def test_a_gamepad_opens_and_works_the_menu
    window = open_window
    press_pad(:back)
    press_pad(:start)
    window.show(Array.new(240 * 160, 0), 240, 160)
    press_pad(:dpad_down)
    press_pad(:a)

    assert window.hold_while_paused
    refute window.hold_while_paused, "Resume should have closed the menu"
  ensure
    window&.close
  end

  # The guide button opens it alone, and B closes it.
  def test_the_guide_button_opens_the_menu_and_b_closes_it
    window = open_window
    press_pad(:guide)
    window.show(Array.new(240 * 160, 0), 240, 160)
    press_pad(:b)

    assert window.hold_while_paused
    refute window.hold_while_paused
  ensure
    window&.close
  end

  # B closes the menu and leaves a pause from before it as it was; only Resume carries on. Still
  # paused, the window goes on waiting, and so reads the window being closed after B.
  def test_b_leaves_a_pause_from_before_the_menu
    window = open_window
    press_key(SDL::PAUSE)
    press_pad(:guide)
    window.show(Array.new(240 * 160, 0), 240, 160)
    press_pad(:b)
    push_event([SDL::EVENT_QUIT].pack("L"))

    assert window.hold_while_paused
    assert window.stop?, "B ended the pause from before the menu"
  ensure
    window&.close
  end

  # Back alone is the console's Select, and opens nothing.
  def test_back_alone_opens_no_menu
    window = open_window
    press_pad(:back)
    window.show(Array.new(240 * 160, 0), 240, 160)

    refute window.hold_while_paused
  ensure
    window&.close
  end

  # A game that says it has no menu has none: F1 does nothing.
  def test_a_window_with_no_menu_ignores_f1
    window = open_window(menu: false)
    press_key(SDL::MENU)
    window.show(Array.new(240 * 160, 0), 240, 160)

    refute window.hold_while_paused
  ensure
    window&.close
  end

  # Closing the window while the game is paused ends the pause and stops the play.
  def test_closing_a_paused_window_stops_the_play
    window = open_window
    press_key(SDL::PAUSE)
    window.show(Array.new(240 * 160, 0), 240, 160)
    push_event([SDL::EVENT_QUIT].pack("L"))

    assert window.hold_while_paused
    assert window.stop?
  ensure
    window&.close
  end

  # A window given a settings file opens as it says, and its keys are the file's: here a bigger
  # window, and Q to pause.
  def test_a_window_plays_as_its_settings_file_says
    Dir.mktmpdir do |dir|
      path = File.join(dir, "settings.txt")
      File.write(path, "scale = 2\nhotkey.pause = Q\n")
      window = open_window(settings_file: path)
      press_key(20) # Q
      window.show(Array.new(240 * 160, 0), 240, 160)
      press_key(20)

      assert_equal [480, 320], window.window_size
      assert window.hold_while_paused
    ensure
      window&.close
    end
  end

  # What the menu changes is written to the file, there for the next window, and the desktop build.
  def test_a_change_in_the_menu_is_written_to_the_settings_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "settings.txt")
      window = open_window(settings_file: path)
      press_key(SDL::MENU)
      window.show(Array.new(240 * 160, 0), 240, 160)
      %i[right right down left].each { |key| press_key(SDL::MENU_KEYS.key(key)) }
      press_key(SDL::MENU)
      window.hold_while_paused
      window.close

      assert_includes File.read(path), "volume = 90\n"
    end
  end

  # A size asked for on the command line is for this play: a change in the menu to something else
  # writes that change, and leaves the size the file keeps alone.
  def test_a_size_asked_for_is_not_written_to_the_settings_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "settings.txt")
      window = SDL.new(title: "TEST", scale: 2, settings_file: path)
      press_key(SDL::MENU)
      window.show(Array.new(240 * 160, 0), 240, 160)
      %i[right right down left].each { |key| press_key(SDL::MENU_KEYS.key(key)) }
      press_key(SDL::MENU)
      window.hold_while_paused
      window.close

      assert_includes File.read(path), "volume = 90\n"
      assert_includes File.read(path), "scale = 3\n"
    end
  end

  # What a settings file says that cannot be used is kept for the window's player to be told.
  def test_a_settings_file_that_cannot_all_be_used_says_what
    Dir.mktmpdir do |dir|
      path = File.join(dir, "settings.txt")
      File.write(path, "volume = loud\n")
      window = open_window(settings_file: path)

      assert_match(/Line 1: volume is a whole number/, window.settings_problems.join("\n"))
    ensure
      window&.close
    end
  end

  # A gamepad's buttons are the console's in its own layout, as the desktop build sets them to begin
  # with: A on the right, B below it, and the D-pad the directions.
  def test_a_gamepads_buttons_are_the_consoles
    held = SDL.pad_buttons(down: [SDL::PAD_EAST, SDL::PAD_SOUTH, SDL::PAD_DPAD_UP, SDL::PAD_START], stick_x: 0, stick_y: 0)

    assert_equal %i[a b up start].sort, held.sort
  end

  # The left stick moves too, once it is pushed past a little way from the middle, so a stick that
  # rests slightly off centre moves nothing.
  def test_the_left_stick_moves_past_its_dead_zone
    resting = SDL.pad_buttons(down: [], stick_x: 4000, stick_y: -4000)
    pushed = SDL.pad_buttons(down: [], stick_x: 30_000, stick_y: -30_000)

    assert_empty resting
    assert_equal %i[right up].sort, pushed.sort
  end

  # A picture of a size the window was not opened for is refused in words, never read past.
  def test_a_picture_of_another_size_is_refused
    window = open_window

    error = assert_raises(ArgumentError) { window.show(Array.new(160 * 144, 0), 160, 144) }
    assert_match(/240x160 picture/, error.message)
  ensure
    window&.close
  end

  # A device keeps the console's time on the machine's own clock.
  def test_the_window_waits_on_the_machines_clock
    window = open_window
    start = window.now
    window.wait_until(start + 0.02)

    assert_operator window.now - start, :>=, 0.02
  ensure
    window&.close
  end

  # SDL3 somewhere it is not is said in plain words, naming where it looked and what to install.
  def test_sdl3_not_found_says_what_to_install
    error = assert_raises(SDL::Missing) { SDL.new(title: "TEST", scale: 1, library: "/nowhere/libSDL3.dylib") }

    assert_match(%r{cannot open SDL3 at /nowhere/libSDL3.dylib}, error.message)
    assert_match(/brew install sdl3/, error.message)
  end

  private

  # A window one picture big, or the size a settings file says when it is given one.
  def open_window(menu: true, settings_file: nil)
    flunk "SDL3 is not installed: #{SDL::INSTALL_LINE}" unless SDL.available?

    SDL.new(title: "TEST", scale: (1 unless settings_file), menu: menu, settings_file: settings_file)
  end

  # SDL told a key went down, or came up, as a keyboard would tell it.
  def press_key(scancode, down: true)
    event = "\0".b * SDL::EVENT_BYTES
    event[0, 4] = [down ? SDL::EVENT_KEY_DOWN : SDL::EVENT_KEY_UP].pack("L")
    event[SDL::KEY_SCANCODE_AT, 4] = [scancode].pack("L")
    event[SDL::KEY_DOWN_AT] = down ? "\1" : "\0"
    push_event(event)
  end

  # SDL told a gamepad's button went down, or came up, as a gamepad would tell it.
  def press_pad(button, down: true)
    event = "\0".b * SDL::EVENT_BYTES
    event[0, 4] = [down ? SDL::EVENT_PAD_BUTTON_DOWN : SDL::EVENT_PAD_BUTTON_UP].pack("L")
    event[SDL::PAD_ID_AT, 4] = [7].pack("L")
    event[SDL::PAD_BUTTON_AT] = [SDL::PAD_CODES.fetch(button)].pack("C")
    event[SDL::PAD_BUTTON_AT + 1] = down ? "\1" : "\0"
    push_event(event)
  end

  def push_event(bytes)
    event = Fiddle::Pointer.malloc(SDL::EVENT_BYTES, Fiddle::RUBY_FREE)
    event[0, bytes.bytesize] = bytes
    SDL.binding_for(nil).SDL_PushEvent(event)
  end
end
