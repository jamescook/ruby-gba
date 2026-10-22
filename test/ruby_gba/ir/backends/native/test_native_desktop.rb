# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require "fileutils"
require "open3"
require "tmpdir"
require RubyGBA.root.join("examples/pong").to_s

# The program a player runs — pong with its window, built with SDL — is the same program the
# tests drive, and it stands on its own.
#
# Only under `rake test:lowering:native SDL=1`: the first desktop build fetches SDL's source over the
# network and compiles it, which no ordinary run of the suite should have to wait for. One test
# of pong, because each desktop build is a whole game built with SDL — and one of a game of a few
# lines that saves, since pong keeps nothing and the window's save file is the window's own code —
# and one of a game that counts its frames and the console buttons held, since what a player does
# to the window (hotkeys, pause, fast forward, volume, the settings file, the menu) is judged by
# what the game did and did not see, and what the speaker was given.
class TestNativeDesktop < Minitest::Test
  include NativeComparison

  RUN = Ractor.make_shareable({ 10 => %i[down], 14 => %i[up], 20 => %i[a] })
  FRAMES = 40

  # The title's menus worked the way a person works them, each button held for several frames:
  # down to the music row and A to turn it off, down to DIFFICULTY and A to open it, up to NORMAL
  # and A to choose it.
  MENU_RUN = Ractor.make_shareable(
    NativeComparison.held_for([10..15, :down], [30..38, :a], [50..55, :down], [70..78, :a], [95..100, :up], [115..122, :a])
  )
  MENU_FRAMES = 140

  # SDL's stand-ins for a display and for sound, so the window needs no screen and a test does
  # not play pong out of the speakers of whoever runs it.
  NO_SCREEN_OR_SPEAKER = { "SDL_VIDEO_DRIVER" => "dummy", "SDL_AUDIO_DRIVER" => "dummy" }.freeze

  def test_the_program_a_player_runs
    Dir.mktmpdir do |dir|
      exe = Native.new.build_desktop(PongGame::GAME, File.join(dir, "pong"), err: nil)

      assert_runs_headless_like_the_interpreter(exe)
      assert_keys_work_the_menus_through_the_window(exe)
      assert_says_how_evenly_its_pictures_were_shown(exe)
      assert_keeps_running_with_its_window(exe)
      assert_needs_nothing_installed(exe) if RUBY_PLATFORM.include?("darwin")
    end
  end

  # A press of A on two frames of a short run, for the game below.
  KEPT_RUN = Ractor.make_shareable({ 3 => %i[a], 7 => %i[a] })
  KEPT_FRAMES = 12

  # A game that keeps one number in save memory: 5 on a new cartridge, and two more at each
  # press of A. Made where it is used, since a game is not something a test may keep in a
  # constant.
  private def game_that_keeps_a_count
    RubyGBA.game("KEEPER") do
      screen :bitmap
      best = save_var :best, 5
      game_loop do
        clear_screen :black
        pressed(:a).then { best.add! 2 }
      end
    end
  end

  # THE WINDOW KEEPS THE GAME'S SAVE IN A FILE, holding the bytes the interpreter's save memory
  # holds after the same presses — a .sav file, as an emulator keeps one.
  def test_the_program_a_player_runs_keeps_its_save_in_a_file
    game = game_that_keeps_a_count
    saved = SaveImage.new
    Reference.new(save: saved).input_each_frame { |frame| KEPT_RUN.fetch(frame, []) }
             .run(Native.new.checked_program(game, err: nil), frames: KEPT_FRAMES)
    assert_equal 9, saved.word(RubyGBA::IR::SaveLayout.save_var_at(0)), "two presses should take the count from 5 to 9"

    Dir.mktmpdir do |dir|
      exe = Native.new.build_desktop(game, File.join(dir, "keeper"), err: nil)

      assert_keeps_its_save_in_the_file_it_is_told(exe, File.join(dir, "told.sav"), saved)
      assert_writes_its_save_while_it_is_still_running(exe, File.join(dir, "running.sav"))
      assert_refuses_a_file_that_is_not_its_save(exe, File.join(dir, "other.sav"))
    end
  end

  # Told nothing, it keeps the save where the operating system keeps a program's own files for
  # the person using the computer, in a folder named for the game. The test says where that
  # person's files are, in the two ways a Mac and a Linux machine are told, so nothing is
  # written among the files of whoever runs it.
  def test_the_program_a_player_runs_keeps_its_save_among_the_files_of_whoever_plays
    skip "only a Mac and Linux can be told where a person's files are" unless RUBY_PLATFORM.match?(/darwin|linux/)

    game = game_that_keeps_a_count
    saved = SaveImage.new
    Reference.new(save: saved).input_each_frame { |frame| KEPT_RUN.fetch(frame, []) }
             .run(Native.new.checked_program(game, err: nil), frames: KEPT_FRAMES)
    Dir.mktmpdir do |dir|
      exe = Native.new.build_desktop(game, File.join(dir, "keeper"), err: nil)

      assert_keeps_its_save_among_the_files_of_whoever_plays(exe, File.join(dir, "home"), saved)
    end
  end

  # A game that counts its frames and, for each console button, the frames it was held: what the
  # window does to itself must leave every one of these as a run with none of it would, and what a
  # button does must show in its own. It plays a long note so there is a sound to hear.
  private def game_that_counts
    RubyGBA.game("WINDOWED") do
      screen :bitmap
      enable_sound
      song :tune do
        tempo 240
        voice :melody do
          duty :half
          30.times do
            note :A4, :whole
            note :C5, :whole
          end
        end
      end
      play_song :tune
      frames = var :frames, 0
      counters = TestNativeDesktop::BUTTONS.to_h { |name| [name, var(:"held_#{name}", 0)] }
      game_loop do
        clear_screen :black
        frames.add! 1
        counters.each { |name, counter| held(name).then { counter.add! 1 } }
      end
    end
  end

  BUTTONS = %i[a b select start right left up down r l].freeze
  BUTTONS_HELD = BUTTONS.map { |name| :"held_#{name}" }.freeze

  # WHAT A PLAYER DOES TO THE WINDOW, judged by what the game saw and what came out: hotkeys, pause
  # and step, fast forward, the volume, the settings file and the menu over the picture. The logic
  # of each is tested with no window (test_native_window.rb); this is that the window does it.
  def test_the_window_a_player_controls
    Dir.mktmpdir do |dir|
      exe = Native.new.build_desktop(game_that_counts, File.join(dir, "windowed"), err: nil)

      assert_hotkeys_never_reach_the_game(exe, dir)
      assert_pause_holds_the_game_and_a_step_runs_one_frame(exe, dir)
      assert_a_pause_is_not_the_game_running_late(exe, dir)
      assert_fast_forward_plays_faster_with_the_game_none_the_wiser_and_no_sound(exe, dir)
      assert_volume_and_mute_change_what_the_speaker_is_given(exe, dir)
      assert_the_window_opens_the_size_it_was_left_at(exe, dir)
      assert_the_keys_can_be_chosen_in_the_settings_file(exe, dir)
      assert_a_script_cannot_hold_a_button_with_no_key(exe, dir)
      assert_a_changed_setting_is_written_to_the_file_and_read_back(exe, dir)
      assert_a_file_that_cannot_be_used_is_said_and_the_game_plays_on(exe, dir)
      assert_the_menu_is_drawn_over_the_picture(exe, dir)
      assert_the_frame_time_shows_without_the_frame_rate(exe, dir)
    end
  end

  # A MAC'S RETINA SCREEN has two pixels to a point each way, and SDL's stand-in display has one, so
  # only a real window can show the menu drawn at the screen's own scale. Drawn at the wrong one it
  # lands at half its size in the top left, away from the mouse, with its text cut off. A real
  # window opens on this Mac's screen for a few seconds.
  def test_the_menu_is_drawn_at_the_screens_own_scale
    skip "only a Mac's own screen is checked here; the stand-in display has no scale" unless RUBY_PLATFORM.include?("darwin")

    Dir.mktmpdir do |dir|
      exe = Native.new.build_desktop(game_that_counts, File.join(dir, "windowed"), err: nil)
      window, = picture_of_window(exe, dir, ["0 hotkey:menu"], frames: 40, env: { "SDL_VIDEO_DRIVER" => nil })
      top = 0...(window.height / 6)

      assert_operator window.text_in((window.width * 3 / 4)...window.width, top), :>, 50,
                      "the frame rate is written in the top right corner of the whole window"
      assert_operator window.text_in((window.width * 7 / 20)...(window.width / 2), 0...(window.height / 24)), :>, 50,
                      "the menu bar is drawn full size, its last menu just short of the middle"
    end
  end

  # One file for every game and one for each, both read, the game's over the player's; a change is
  # written to the game's file where there is one and otherwise the player's. The test says where
  # the person's files are, in the two ways a Mac and a Linux machine are told, so nothing is
  # written among the files of whoever runs it.
  def test_the_players_settings_file_and_the_games_own
    skip "only a Mac and Linux can be told where a person's files are" unless RUBY_PLATFORM.match?(/darwin|linux/)

    Dir.mktmpdir do |dir|
      exe = Native.new.build_desktop(game_that_counts, File.join(dir, "windowed"), err: nil)

      assert_the_players_file_and_the_games_file_are_read_and_the_games_wins(exe, dir)
    end
  end

  private

  Played = Struct.new(:variables, :said, :seconds, :audio, keyword_init: true)

  # A run of the window (on SDL's stand-ins, and for a settings file of its own unless it is
  # given one) of +frames+ frames with a script's lines, a line each, as --scripted-keys reads
  # them; the frames' worth of lines are made up to with idle ones. +audio+ saves what the
  # speaker was given, through SDL's disk driver, and tells where.
  def play_window(exe, dir, lines, frames:, options: [], env: {}, audio: false, own_settings: true)
    script = lines + ["0"] * [frames - lines.length, 0].max
    needs_a_file = own_settings && !options.include?("--settings-file") && !options.include?("--usual-settings")
    settings = needs_a_file ? ["--settings-file", File.join(dir, "none-#{rand(1 << 30)}.txt")] : []
    environment = NO_SCREEN_OR_SPEAKER.merge(env)
    raw = File.join(dir, "audio-#{rand(1 << 30)}.raw")
    environment = environment.merge("SDL_AUDIO_DRIVER" => "disk", "SDL_AUDIO_DISK_OUTPUT_FILE" => raw) if audio
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    printed, said, status = Open3.capture3(environment, exe, "--scripted-keys", frames.to_s, *settings, *options,
                                           stdin_data: script.map { |line| "#{line}\n" }.join)
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_predicate status, :success?, said
    Played.new(variables: Native::HeadlessRun.variables_in(printed.lines.map(&:chomp)), said: said, seconds: took,
               audio: audio ? File.binread(raw).unpack("s<*") : nil)
  end

  # What the game itself counted, which nothing the window does may change.
  def game_saw(played) = played.variables.slice(:frames, *BUTTONS_HELD)

  # Every key the window keeps for itself, pressed by the key and by the hotkey's name (so also
  # held and let go for fast forward), among the frames of a game being played. The game sees
  # none of them: it counts the same frames and no button.
  def assert_hotkeys_never_reach_the_game(exe, dir)
    words = { 3 => "key:F3", 4 => "key:M", 5 => "key:F1", 6 => "key:F11", 7 => "keydown:Tab", 9 => "keyup:Tab",
              12 => "hotkey:frame_rate", 13 => "hotkey:mute", 14 => "hotkey:menu", 15 => "hotkey:fullscreen",
              16 => "hotkeydown:fast_forward", 20 => "hotkeyup:fast_forward" }
    lines = (1..30).map { |frame| ["0", words[frame]].compact.join(" ") }
    plain = play_window(exe, dir, [], frames: 30)
    pressed = play_window(exe, dir, lines, frames: 30)

    assert_equal game_saw(plain), game_saw(pressed), "a hotkey must never reach the game"
    assert_equal [0] * 10, game_saw(pressed).values_at(*BUTTONS_HELD)
    assert_operator pressed.variables[:frames], :>, 25, "and the game still played its frames"
  end

  # A pause holds the game where it is: lines that come while it is paused are not frames, and the
  # game has played the same frames at the end as if they had never been. A step lets one more frame
  # run, and only one.
  def assert_pause_holds_the_game_and_a_step_runs_one_frame(exe, dir)
    paused_at_three = ["0", "0", "0 hotkey:pause"]
    held = play_window(exe, dir, paused_at_three + ["0"] * 30, frames: 100)
    held_less = play_window(exe, dir, paused_at_three + ["0"] * 5, frames: 100)
    one_step = play_window(exe, dir, paused_at_three + ["0"] * 5 + ["0 hotkey:step"] + ["0"] * 5, frames: 100)
    two_steps = play_window(exe, dir, paused_at_three + ["0 hotkey:step", "0", "0 hotkey:step"] + ["0"] * 5, frames: 100)

    assert_equal game_saw(held), game_saw(held_less), "the game should not move while it is paused, however long"
    assert_equal game_saw(held)[:frames] + 1, game_saw(one_step)[:frames], "a step runs one frame"
    assert_equal game_saw(held)[:frames] + 2, game_saw(two_steps)[:frames], "two steps run two"

    # Resumed, it plays on from where it was, and has seen the same frames as a game never paused.
    lines = ["0"] * 5 + ["0 hotkey:pause"] + ["0"] * 20 + ["0 hotkey:pause"]
    assert_equal game_saw(play_window(exe, dir, [], frames: 20)), game_saw(play_window(exe, dir, lines, frames: 20))
  end

  # A pause, however short, is not the game falling behind: the frames after it come at the console's
  # pace and never in a rush to make up the time. Two frames' worth of pause is what the rule for a
  # game a frame or two late would have caught up on, with the pictures a few milliseconds apart.
  def assert_a_pause_is_not_the_game_running_late(exe, dir)
    lines = ["0"] * 10 + ["0 hotkey:pause", "0", "0", "0 hotkey:pause"]
    played = play_window(exe, dir, lines, frames: 40, options: ["--frame-times"])
    nearest = played.said[/^pictures: 40, ([\d.]+) to/, 1]

    refute_nil nearest, played.said
    assert_operator nearest.to_f, :>, 10.0, "no frame should have been rushed after the pause: #{played.said}"
  end

  # Fast forward, held, plays several frames for each picture: the game sees the same frames, in a
  # fraction of the time, and the speaker is given next to nothing rather than a pile of sound it
  # would play late.
  def assert_fast_forward_plays_faster_with_the_game_none_the_wiser_and_no_sound(exe, dir)
    normal = play_window(exe, dir, [], frames: 120, audio: true)
    fast = play_window(exe, dir, ["0 hotkeydown:fast_forward"], frames: 120, audio: true)

    assert_equal game_saw(normal), game_saw(fast), "the game should see ordinary frames"
    assert_operator fast.seconds, :<, normal.seconds * 0.6, "four frames to a picture should be well under the time"
    assert_operator normal.audio.count(&:nonzero?), :>, 50_000, "the game's sound should be heard at its own speed"
    assert_operator fast.audio.count(&:nonzero?), :<, normal.audio.count(&:nonzero?) * 0.2, "fast forward should be near silent"
  end

  # The player's volume is applied as the sound goes to the speaker; mute silences it.
  def assert_volume_and_mute_change_what_the_speaker_is_given(exe, dir)
    settings = File.join(dir, "volume.txt")
    loud = play_window(exe, dir, [], frames: 60, audio: true).audio.map(&:abs).max
    File.write(settings, "volume = 50\n")
    half = play_window(exe, dir, [], frames: 60, audio: true, options: ["--settings-file", settings]).audio.map(&:abs).max
    File.write(settings, "volume = 0\n")
    none = play_window(exe, dir, [], frames: 60, audio: true, options: ["--settings-file", settings]).audio.map(&:abs).max
    muted = play_window(exe, dir, ["0 hotkey:mute"], frames: 60, audio: true).audio

    assert_operator loud, :>, 1000
    assert_in_delta loud / 4.0, half, loud / 4.0 * 0.1, "half the volume is a quarter of the amplitude"
    assert_equal 0, none
    assert_operator muted.count(&:nonzero?), :<, muted.length * 0.1, "mute silences the sound"
  end

  # What is in the BMP the window saves (--window-picture): its size, and the colours of its pixels.
  Window = Struct.new(:width, :height, :pixels) do
    def lit_in(x_range, y_range) = y_range.sum { |y| x_range.count { |x| pixels[(y * width) + x] != 0 } }

    # Pixels near white: the menu's text, which a box drawn with nothing in it does not have.
    def text_in(x_range, y_range) = y_range.sum { |y| x_range.count { |x| pixels[(y * width) + x] > 600 } }
  end

  def window_picture(path)
    bytes = File.binread(path)
    offset, width, height, bits = bytes.unpack("@10V @18l< l< @28v")
    step = bits / 8
    stride = ((width * bits) + 31) / 32 * 4
    pixels = (0...height).flat_map do |y|
      row = bytes.byteslice(offset + ((height - 1 - y) * stride), width * step)
      (0...width).map { |x| row.byteslice(x * step, 3).unpack("C3").sum }
    end
    Window.new(width, height, pixels)
  end

  def picture_of_window(exe, dir, lines, frames:, options: [], env: {})
    picture = File.join(dir, "window-#{rand(1 << 30)}.bmp")
    played = play_window(exe, dir, lines, frames: frames, options: ["--window-picture", picture] + options, env: env)
    [window_picture(picture), played]
  end

  # The window opens as large as the settings say, a whole number of times the console's screen.
  def assert_the_window_opens_the_size_it_was_left_at(exe, dir)
    settings = File.join(dir, "scale.txt")
    File.write(settings, "scale = 5\n")
    window, = picture_of_window(exe, dir, [], frames: 5, options: ["--settings-file", settings])
    default, = picture_of_window(exe, dir, [], frames: 5)

    assert_equal [1200, 800], [window.width, window.height]
    assert_equal [720, 480], [default.width, default.height], "and 3x when it has been told nothing"
  end

  # The settings file chooses which key is which console button: the key it names is the button, and
  # the key that was the button no longer is.
  def assert_the_keys_can_be_chosen_in_the_settings_file(exe, dir)
    settings = File.join(dir, "keys.txt")
    File.write(settings, "key.a = Q\nkey.b = Space\nkey.b = Left Alt\n")
    held_q = play_window(exe, dir, ["0", "0 keydown:Q", "0", "0", "0", "0 keyup:Q"], frames: 12, options: ["--settings-file", settings])
    tapped_x = play_window(exe, dir, ["0", "0 key:X"], frames: 12, options: ["--settings-file", settings])
    second_key = play_window(exe, dir, ["0", "0 keydown:Left_Alt", "0", "0 keyup:Left_Alt"], frames: 12, options: ["--settings-file", settings])

    assert_operator held_q.variables[:held_a], :>=, 3, "Q should be A now"
    assert_equal 0, tapped_x.variables[:held_a], "and X is not"
    assert_operator second_key.variables[:held_b], :>=, 1, "a button's second key works as well"
    assert_equal 0, tapped_x.variables[:held_b]
    assert_empty held_q.said.lines.grep(/cannot use/), "a file like that is nothing to complain of"
  end

  # A script holds a console button by pressing a key it has; a button with no key cannot be held
  # from the keyboard at all, and the script stops and says so rather than playing on without it.
  def assert_a_script_cannot_hold_a_button_with_no_key(exe, dir)
    settings = File.join(dir, "no-a.txt")
    File.write(settings, "key.a = none\n")
    _printed, said, status = Open3.capture3(NO_SCREEN_OR_SPEAKER, exe, "--scripted-keys", "3", "--settings-file", settings,
                                            stdin_data: "0\n1\n0\n")

    refute_predicate status, :success?
    assert_match(/A has no key/, said)
  end

  def settings_lines(path) = File.readlines(path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }

  # What a player changes is written back to the file, every setting, and the next run opens that
  # way.
  def assert_a_changed_setting_is_written_to_the_file_and_read_back(exe, dir)
    settings = File.join(dir, "kept.txt")
    play_window(exe, dir, ["0 hotkey:fullscreen hotkey:frame_rate hotkey:mute"], frames: 5, options: ["--settings-file", settings])

    kept = settings_lines(settings)
    assert_includes kept, "fullscreen = on"
    assert_includes kept, "frame_rate = off"
    assert_includes kept, "mute = on"
    assert_includes kept, "scale = 3"
    assert_includes kept, "key.select = Right Shift"
    assert_includes kept, "pad.a = east"
    assert_includes kept, "hotkey.pause = P"
    refute_path_exists "#{settings}.writing"

    # A run that changes nothing writes nothing: the file is as it was left, down to the second.
    before = File.mtime(settings)
    sleep 0.05
    play_window(exe, dir, [], frames: 5, options: ["--settings-file", settings])
    assert_equal before, File.mtime(settings)

    # A window left fullscreen opens fullscreen.
    assert_equal 5, play_window(exe, dir, [], frames: 5, options: ["--settings-file", settings]).variables[:frames]

    # The next run opens with the frame rate hidden: its corner of the window is as black as the
    # game's picture. (And a window told nothing has it, which is how the corner is told.)
    File.write(settings, File.read(settings).sub("fullscreen = on", "fullscreen = off"))
    shown, = picture_of_window(exe, dir, [], frames: 40)
    hidden, = picture_of_window(exe, dir, [], frames: 40, options: ["--settings-file", settings])
    corner = [(shown.width - 140)...(shown.width - 10), 30...70]
    assert_operator shown.text_in(*corner), :>, 50, "the frame rate shows to begin with, its number written in it"
    assert_equal 0, hidden.lit_in(*corner), "and not when the settings say not"
  end

  # A file that cannot be used is said in plain words, on the error stream and over the picture as
  # the window opens, and the window opens anyway, as it starts.
  def assert_a_file_that_cannot_be_used_is_said_and_the_game_plays_on(exe, dir)
    plain_window, plain_run = picture_of_window(exe, dir, [], frames: 20)
    garbage = File.join(dir, "garbage.txt")
    File.write(garbage, "{\"this\": \"is not settings\"}\nvolume = loud\nkey.a = Nonesuch\n")
    folder = File.join(dir, "a-folder.txt")
    Dir.mkdir(folder)

    garbage_window, from_garbage = picture_of_window(exe, dir, [], frames: 20, options: ["--settings-file", garbage])
    from_folder = play_window(exe, dir, [], frames: 20, options: ["--settings-file", folder])

    assert_equal game_saw(plain_run), game_saw(from_garbage)
    assert_match(/cannot use some of the settings file/, from_garbage.said)
    assert_match(/Line 2: volume is a whole number/, from_garbage.said)
    assert_match(/Line 3: "Nonesuch" is not a key's name/, from_garbage.said)
    middle = [40...400, 100...400]
    assert_operator garbage_window.lit_in(*middle), :>, plain_window.lit_in(*middle) + 10_000,
                    "what was wrong is said over the picture, for a player with no terminal"
    assert_equal game_saw(plain_run), game_saw(from_folder)
    assert_match(/The window cannot read .*a-folder\.txt/, from_folder.said)
  end

  # The game's own file keeps only what it says and what changed while the game played, so a later
  # change to the player's file still reaches the game.
  def assert_the_players_file_and_the_games_file_are_read_and_the_games_wins(exe, dir)
    home = File.join(dir, "settings-home")
    # A Mac keeps a program's files under Library/Application Support in the person's folder; Linux
    # keeps them straight in the folder it is told.
    programs = RUBY_PLATFORM.include?("darwin") ? File.join(home, "Library", "Application Support") : home
    everyones = File.join(programs, "ruby-gba", "(all games)", "settings.txt")
    games = File.join(programs, "ruby-gba", "WINDOWED", "settings.txt")
    env = { "XDG_DATA_HOME" => home, "CFFIXED_USER_HOME" => home }
    use = ->(lines = [], **more) { picture_of_window(exe, dir, lines, frames: 5, options: ["--usual-settings"], env: env, **more) }

    # A scripted run that was not asked for them leaves the player's files alone.
    play_window(exe, dir, ["0 hotkey:mute"], frames: 3, env: env, own_settings: false)
    refute_path_exists everyones

    # Nothing yet: a change makes the player's file.
    use.call(["0 hotkey:mute"])
    assert_includes settings_lines(everyones), "mute = on"

    # The player's file is read; the game's, once there is one, is read over it.
    FileUtils.mkdir_p(File.dirname(games))
    File.write(everyones, "scale = 4\nfast_forward_speed = 6\n")
    assert_equal 960, use.call.first.width
    File.write(games, "scale = 5\n")
    assert_equal 1200, use.call.first.width
    File.write(games, "scale = 5\nfast_forward_speed = 7\n")
    before = File.read(everyones)
    use.call(["0 hotkey:frame_rate"])
    assert_includes settings_lines(games), "frame_rate = off"
    assert_includes settings_lines(games), "scale = 5"
    assert_includes settings_lines(games), "fast_forward_speed = 7"
    assert_empty settings_lines(games).grep(/^(volume|mute|key\.|pad\.|hotkey\.)/), "the game's file keeps only its own"
    assert_equal before, File.read(everyones), "the player's file is left as it was"

    # A key the player gives A in the shared file afterwards is A in this game too.
    File.write(everyones, "#{before}key.a = Q\n")
    _window, held_q = use.call(["0", "0 keydown:Q", "0", "0 keyup:Q"])
    assert_operator held_q.variables[:held_a], :>=, 1, "the player's file still reaches the game"
  end

  # The menu bar is drawn over the picture (the game's own is black there), and the frame rate in the
  # corner; the pause says so; a window of the menu's draws when it is opened; and none of them is the game's.
  def assert_the_menu_is_drawn_over_the_picture(exe, dir)
    window, = picture_of_window(exe, dir, [], frames: 20)
    bar = [0...window.width, 0...20]

    assert_operator window.lit_in(*bar), :>, window.width * 10, "the menu bar should be along the top"

    paused, = picture_of_window(exe, dir, ["0", "0 hotkey:pause"], frames: 20)
    corner = [(window.width - 140)...(window.width - 10), 30...100]
    assert_operator paused.lit_in(*corner), :>, window.lit_in(*corner), "a pause says PAUSED under the frame rate"

    opened, = picture_of_window(exe, dir, ["0 panel:controls"], frames: 20)
    middle = [40...400, 100...400]
    assert_operator opened.lit_in(*middle), :>, window.lit_in(*middle) + 20_000, "the window of keys opens"

    variables, played = picture_of_window(exe, dir, ["0 panel:variables hotkey:pause"], frames: 20)
    assert_operator variables.lit_in(*middle), :>, window.lit_in(*middle) + 10_000
    assert_equal 0, played.variables.values_at(*BUTTONS_HELD).sum, "opening a window of the menu is not a button"
  end

  # The frame time is the developer's own reading, and shows in the corner with the frame rate hidden.
  def assert_the_frame_time_shows_without_the_frame_rate(exe, dir)
    settings = File.join(dir, "frame-time.txt")
    File.write(settings, "frame_rate = off\nframe_time = on\n")
    shown, = picture_of_window(exe, dir, [], frames: 40, options: ["--settings-file", settings])
    corner = [(shown.width - 200)...(shown.width - 10), 30...70]

    assert_operator shown.text_in(*corner), :>, 50, "the frame time is written in the corner"
  end

  public

  # THE SAME GAME FOR ANOTHER COMPUTER, built from this one: zig carries the C library of each, and
  # SDL is compiled for each from its own source. These are only built here, not run — nothing
  # here can run them — so what is checked is that each is a program for the computer it was asked
  # for, read off the first bytes of the file the way that computer reads them.
  WINDOWS_PROGRAM = "MZ".b
  LINUX_PROGRAM = "\x7FELF".b
  ELF_MACHINE = { linux: 0x3E, linux_arm: 0xB7 }.freeze # x86-64 and 64-bit ARM, at byte 18

  def test_a_program_for_windows_and_for_linux_is_built_from_here
    Dir.mktmpdir do |dir|
      windows = Native.new.build_desktop(PongGame::GAME, File.join(dir, "pong.exe"), target: :windows, err: nil)
      assert_equal WINDOWS_PROGRAM, File.binread(windows, 2)

      ELF_MACHINE.each do |target, machine|
        linux = Native.new.build_desktop(PongGame::GAME, File.join(dir, "pong-#{target}"), target: target, err: nil)
        head = File.binread(linux, 20)
        assert_equal LINUX_PROGRAM, head[0, 4], "#{target} is a Linux program"
        assert_equal machine, head.byteslice(18, 2).unpack1("v"), "#{target} is for the processor asked for"
      end
    end
  end

  private

  # What a run of the game with its window (on SDL's stand-in display) printed at its end, with
  # keys pressed from +presses+.
  def variables_after(exe, frames, presses, *options, env: {})
    input = (1..frames).map { |frame| "#{Native::HeadlessRun.button_mask(presses.fetch(frame, []))}\n" }.join
    printed = Native::Zig.run_program(exe, args: ["--scripted-keys", frames, *options], input: input,
                                           env: NO_SCREEN_OR_SPEAKER.merge(env))
    Native::HeadlessRun.variables_in(printed.lines.map(&:chomp))
  end

  # Told a file (--save-file), it leaves the save there, with nothing beside it: the new file it
  # writes first has taken the save file's place. Started again, it reads the file before the
  # game starts, so the count carries on from where it was.
  def assert_keeps_its_save_in_the_file_it_is_told(exe, path, saved)
    assert_equal 9, variables_after(exe, KEPT_FRAMES, KEPT_RUN, "--save-file", path)[:best]

    assert_equal saved.to_sav, File.binread(path)
    refute_path_exists "#{path}.writing"
    assert_equal 11, variables_after(exe, 5, { 3 => %i[a] }, "--save-file", path)[:best]
  end

  # The file is written soon after the game saves, and not only as the window closes: A is
  # pressed on the third frame of a run with hours left in it, the file holds the count that
  # press made within a few seconds, and only then is the program stopped — the way a crash
  # stops one, with no chance to write anything. (The file is there before the press, holding
  # the 5 a new cartridge is given as the game starts, so it is the count that is waited for.)
  def assert_writes_its_save_while_it_is_still_running(exe, path)
    keys = "#{path}.keys"
    File.write(keys, "0\n0\n#{Native::HeadlessRun.button_mask(%i[a])}\n")
    pid = Process.spawn(NO_SCREEN_OR_SPEAKER, exe, "--scripted-keys", "1000000", "--save-file", path,
                        in: keys, out: File::NULL, err: File::NULL)
    count = -> { File.exist?(path) && SaveImage.read_sav(path).word(RubyGBA::IR::SaveLayout.save_var_at(0)) }
    give_up = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    sleep 0.05 until count.call == 7 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > give_up

    assert_equal 7, count.call, "the save file should hold the count while the game is still running"
    assert_nil Process.wait(pid, Process::WNOHANG), "and the game should still be running"
  ensure
    if pid
      Process.kill(:KILL, pid)
      Process.wait(pid)
    end
  end

  # The save is in a folder named for the game, under +home+, and holds what the interpreter's does.
  def assert_keeps_its_save_among_the_files_of_whoever_plays(exe, home, saved)
    FileUtils.mkdir_p(home)
    variables_after(exe, KEPT_FRAMES, KEPT_RUN, env: { "CFFIXED_USER_HOME" => home, "XDG_DATA_HOME" => home })
    found = Dir.glob(File.join(home, "**", "save.sav"))

    assert_equal 1, found.length, "one save file should be under #{home}: #{Dir.glob(File.join(home, '**', '*')).inspect}"
    assert found.first.end_with?(File.join("ruby-gba", "KEEPER", "save.sav")), "the folder should be the game's: #{found.first}"
    assert_equal saved.to_sav, File.binread(found.first)
  end

  # A file there that is not as big as the game's save memory is another game's, or damaged: the
  # game does not start, says why, and leaves the file as it is.
  def assert_refuses_a_file_that_is_not_its_save(exe, path)
    File.binwrite(path, "x" * 100)
    _printed, said, status = Open3.capture3(NO_SCREEN_OR_SPEAKER, exe, "--scripted-keys", "2", "--save-file", path,
                                            stdin_data: "0\n0\n")

    refute_predicate status, :success?
    assert_match(/is not a save of this game, whose save is 32768 bytes/, said)
    assert_equal "x" * 100, File.binread(path)
  end

  # Started with --headless it plays a recorded run with no window, and shows the interpreter's
  # picture pixel for pixel.
  def assert_runs_headless_like_the_interpreter(exe)
    input = (1..FRAMES).map { |frame| "#{Native::HeadlessRun.button_mask(RUN.fetch(frame, []))}\n" }.join
    program = Native.new.checked_program(PongGame::GAME, err: nil)
    actual = parse_snapshots(Native::Zig.run_program(exe, args: ["--headless", FRAMES, "--every-picture"], input: input), program)
    expected = reference_snapshots(program, frames: FRAMES, buttons: RUN)

    assert_equal expected.map(&:heading), actual.map(&:heading)
    expected.zip(actual).each { |want, got| assert_same_moment(want, got, :desktop) }
  end

  # Started with its window (on SDL's stand-in display) and keys pressed from a script: each
  # press is a key event through SDL, onto the gamepad the keyboard is, and round the window's own
  # frame loop — the way in that --headless goes round. A key held for several frames must still
  # count once, so the music ends up off, the difficulty screen is opened and left, and the cpu
  # paddle is at NORMAL's speed — where the interpreter ends given the same buttons.
  def assert_keys_work_the_menus_through_the_window(exe)
    input = (1..MENU_FRAMES).map { |frame| "#{Native::HeadlessRun.button_mask(MENU_RUN.fetch(frame, []))}\n" }.join
    printed = Native::Zig.run_program(exe, args: ["--scripted-keys", MENU_FRAMES], input: input, env: NO_SCREEN_OR_SPEAKER)
    program = Native.new.checked_program(PongGame::GAME, err: nil)
    expected = reference_snapshots(program, frames: MENU_FRAMES, buttons: MENU_RUN).last.variables

    assert_equal [0, 0], expected.values_at(:music_on, :state), "the run should turn the music off and come back to the title"
    assert_empty variable_differences(expected, Native::HeadlessRun.variables_in(printed.lines.map(&:chomp)))
  end

  # Asked for its frame times, it says on the error stream what paced the frames and how far
  # apart the pictures were handed over, which is the only way to see a stutter without looking
  # at a screen. The stand-in display says nothing of its rate, so it is told to pace as for a
  # monitor that refreshes sixty times a second: the monitor then paces the game, a picture every
  # sixtieth of a second, and a second's worth of frames takes about a second.
  def assert_says_how_evenly_its_pictures_were_shown(exe)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _printed, said, status = Open3.capture3(NO_SCREEN_OR_SPEAKER, exe, "--scripted-keys", "60", "--frame-times",
                                            "--refresh-rate", "60", stdin_data: "0\n" * 60)
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_predicate status, :success?, said
    assert_match(/^pacing: the monitor, 1 refreshes a picture/, said)
    assert_match(/^uneven \(more than 2 ms from the middle\): \d+/, said)
    middle = said[/^pictures: 60, [\d.]+ to [\d.]+ ms apart, ([\d.]+) in the middle$/, 1]
    assert_in_delta 1000.0 / 60, middle.to_f, 1.5, "the pictures should be a sixtieth of a second apart: #{said}"
    assert_operator took, :>, 0.8, "sixty frames should take about a second"
  end

  # Started normally, with SDL's stand-in display so it needs no screen, it opens its window and
  # is still running a couple of seconds later: nothing stops it but being told to.
  def assert_keeps_running_with_its_window(exe)
    pid = Process.spawn(NO_SCREEN_OR_SPEAKER, exe, err: File::NULL)
    sleep 2
    stopped = Process.wait(pid, Process::WNOHANG)

    assert_nil stopped, "the game stopped on its own"
  ensure
    if pid && stopped.nil?
      Process.kill(:KILL, pid)
      Process.wait(pid)
    end
  end

  # The only libraries it reaches for are the operating system's own: SDL is inside it.
  def assert_needs_nothing_installed(exe)
    libraries = `otool -L #{exe}`.lines.drop(1).map { |line| line.strip.split(" ").first }

    assert_empty libraries.reject { |lib| lib.start_with?("/System/Library/", "/usr/lib/") }
  end
end
