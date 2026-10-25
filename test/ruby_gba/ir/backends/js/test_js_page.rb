# frozen_string_literal: true

require "test_helper"
require "web_page"

# A game built for the web is one page: the picture's canvas, the keys said in words, and the game
# and its runtime in one script, with nothing fetched — so the page opens from a disk. Its script
# is played here in node with a stand-in for the browser (WebPage), so what is checked is the
# page's own driver: the keys it reads, the frames it plays and the picture it puts up.
class TestJSPage < Minitest::Test
  include WebPage
  JS = RubyGBA::IR::Backends::JS

  def test_the_page_holds_the_canvas_and_the_whole_game
    page = built_page

    assert_match(/<canvas id="screen" width="240" height="160"/, page)
    assert_match(/<title>PAGE &lt;&amp;&gt;<\/title>/, page, "the title is said as text, not as markup")
    assert_match(/function\* rg_game_main\(\)/, page)
    assert_match(/function createGame\(host\)/, page)
    refute_match(/<script src=/, page)
  end

  # The page plays a frame of the game on each of the browser's frames, reads the keyboard as the
  # buttons, and puts up the picture the interpreter draws. A key is read after each frame, for
  # the next: one held as the page opens counts from frame 2, and one let go after frame 10 still
  # counts for frame 11, since it was down when that frame's buttons were read.
  def test_the_page_draws_what_the_interpreter_draws_with_the_keys_it_reads
    assert_walks_right_for_frames_two_to_eleven(["down ArrowRight", "play 10", "picture", "up ArrowRight", "play 5", "picture"])
  end

  # A controller laid out the standard way plays the game as the keyboard does, read at the same
  # moment: its d-pad is the console's.
  def test_a_controllers_d_pad_plays_the_game_as_the_arrows_do
    assert_walks_right_for_frames_two_to_eleven(["pad connect", "pad press 15", "play 10", "picture",
                                                 "pad release 15", "play 5", "picture"])
  end

  # The left stick is the d-pad too, once it is pushed past a little way: a stick resting a touch
  # off the middle, as a worn one does, holds nothing.
  def test_the_left_stick_pushed_past_a_little_way_is_the_d_pad
    assert_walks_right_for_frames_two_to_eleven(["pad connect", "pad stick 0.9 0.1", "play 10", "picture",
                                                 "pad stick 0.2 -0.2", "play 5", "picture"])
  end

  # Each of the controller's buttons is the console's button it is labelled as, and the keyboard
  # adds to the controller rather than taking turns with it.
  def test_each_controller_button_is_its_console_button_and_the_keyboard_adds_to_them
    picture = pictures_in(played_page(["pad connect", *[0, 1, 8, 9, 5, 4].map { |n| "pad press #{n}" },
                                       "down ArrowRight", "play 3", "picture"], buttons_game)).first
    held = %i[a b select start r l right]
    interpreter = Reference.new.input_each_frame { |frame| frame >= 2 ? held : [] }.run(buttons_game.program, frames: 3)

    assert_same_picture interpreter.screen.shown, picture, "with A, B, Select, Start, L and R on the controller and right on the keys"
  end

  # The page says under the game whether a controller is being used, and how to get one seen: a
  # browser tells a page about a controller only once a button on it has been pressed.
  def test_the_page_says_when_a_controller_comes_and_goes
    said = played_page(["play 1", "text controller", "pad connect", "play 1", "text controller",
                        "pad disconnect", "play 1", "text controller"]).grep(/\Atext controller /)
    before, during, after = said.map { |line| line.delete_prefix("text controller ") }

    assert_match(/press a button on it/i, before)
    assert_match(/Stand-in Controller/, during)
    assert_equal before, after
  end

  # A page written by a template of the game's own, with nothing on it but the game, plays the
  # game the same: the parts the script fills in are not there, and it does without them.
  def test_a_template_with_only_the_game_plays_it_the_same
    template = "<!doctype html>\n<title><%= title %></title>\n<main class=\"mine\"><%= game %></main>\n"
    steps = ["down ArrowRight", "play 10", "picture", "up ArrowRight", "play 5", "picture", "text controller"]

    assert_includes built_page(template: template), '<main class="mine">'
    assert_includes played_page(steps, template: template), "text controller (none)"
    assert_walks_right_for_frames_two_to_eleven(steps, template: template)
  end

  # The canvas itself says its pixels stay square however big it is drawn — on the page and filling
  # the screen — so a template that leaves the default look out does not get a blurred picture.
  def test_the_canvas_keeps_square_pixels_without_the_default_look
    canvas = built_page(template: "<%= game %>")[/<canvas [^>]*>/]

    assert_match(/image-rendering: pixelated/, canvas)
  end

  # A template that never writes the game would make a page with no game on it, so the build
  # stops and says what to add.
  def test_a_template_without_the_game_is_refused_by_name
    error = assert_raises(JS::LoweringError) { built_page(template: "<p><%= keys %></p>") }

    assert_match(/does not write the game/, error.message)
    assert_includes error.message, "<%= game %>"
  end

  # A key pressed with Cmd, Ctrl or Alt is the browser's shortcut, not the game's button: the game
  # does not see it, and the browser is left to do what it does with it.
  def test_a_key_pressed_with_cmd_ctrl_or_alt_is_left_to_the_browser
    %w[meta ctrl alt].each do |modifier|
      lines = played_page(["down ArrowRight #{modifier}", "play 5", "picture", "state"])
      interpreter = Reference.new.run(walking_game.program, frames: 5)

      assert_same_picture interpreter.screen.shown, pictures_in(lines).first, "with #{modifier} held"
      assert_equal ["state audio=running fullscreen=none kept=0"], lines.grep(/\Astate /), "the key with #{modifier} is the browser's"
    end
  end

  # A tab put behind another pauses the sound and lets go of every key — a key let go while the
  # page is hidden never reaches it, and would be held for ever — and shown again it plays on.
  def test_a_hidden_tab_pauses_the_sound_and_lets_go_of_the_keys
    lines = played_page(["down ArrowRight", "play 3", "hide", "state", "play 30", "show", "state", "play 5", "picture"])
    interpreter = Reference.new.input_each_frame { |frame| (2..4).cover?(frame) ? [:right] : [] }
                           .run(walking_game.program, frames: 8)

    assert_equal ["state audio=suspended fullscreen=none kept=1", "state audio=running fullscreen=none kept=1"],
                 lines.grep(/\Astate /)
    assert_same_picture interpreter.screen.shown, pictures_in(lines).first, "after the tab came back"
  end

  # A page in a frame on another site starts without the keyboard, and a key pressed then goes to
  # the other page: so until it has the keyboard it says to click the game, and once it has it,
  # it says nothing. Losing the keyboard again lets go of every key, which may come up elsewhere —
  # seen here with the pause turned off, so the game plays on to show it.
  def test_a_page_without_the_keyboard_says_to_click_and_lets_go_of_keys_when_it_loses_it
    lines = played_page(["uncheck pause", "play 1", "text said", "focus", "down ArrowRight", "play 3", "text said", "blur",
                         "play 5", "picture"], focused: false)
    interpreter = Reference.new.input_each_frame { |frame| (3..5).cover?(frame) ? [:right] : [] }
                           .run(walking_game.program, frames: 9)

    assert_equal ["text said Click the game to play.", "text said hidden Click the game to play."], lines.grep(/\Atext said/)
    assert_same_picture interpreter.screen.shown, pictures_in(lines).first, "after the keyboard went elsewhere"
  end

  # The button under the game and the F key fill the screen with the game, and the F key puts it
  # back; F with Cmd, Ctrl or Alt stays the browser's.
  def test_the_button_and_the_f_key_fill_the_screen_with_the_game
    lines = played_page(["click fullscreen", "state", "down KeyF", "up KeyF", "state", "down KeyF", "up KeyF", "state",
                         "down KeyF meta", "state"], template: "<%= game %>\n<%= fullscreen %>")

    assert_equal %w[screen none screen screen], lines.grep(/\Astate /).map { |line| line[/fullscreen=(\S+)/, 1] }
  end

  # A page with the pad on the screen fills the screen with the whole page, so the pad comes too: a
  # phone filled with the game alone could not be played.
  def test_a_page_with_the_pad_fills_the_screen_with_the_pad_as_well
    lines = played_page(["click fullscreen", "state"], pointer: :finger)

    assert_equal %w[page], lines.grep(/\Astate /).map { |line| line[/fullscreen=(\S+)/, 1] }
  end

  # +steps+ played on the ticking game's page end on the picture the same page shows after
  # +frames+ of the browser's frames with nothing else happening — so exactly +frames+ were played —
  # and the sound device read at each "state" is in +sound+.
  private def assert_plays_frames(frames, steps, sound, template: nil, focused: true)
    lines = played_page(steps, ticking_game, template: template, focused: focused)
    undisturbed = pictures_in(played_page(["play #{frames}", "picture"], ticking_game, template: template)).last

    assert_same_picture undisturbed, pictures_in(lines).last, "after #{frames} frames played"
    assert_equal sound, lines.grep(/\Astate /).map { |line| line[/audio=(\S+)/, 1] }
  end

  # A page that loses the keyboard to another window pauses — no frames played, the sound
  # suspended — and plays on when it has the keyboard again: a player who looks away does not
  # come back to a game that went on without them.
  def test_a_page_that_loses_the_keyboard_pauses_until_it_has_it_again
    assert_plays_frames(5, ["down KeyQ", "play 3", "blur", "play 10", "state", "focus", "play 2", "state", "picture"],
                        %w[suspended running])
  end

  # The checkbox under the game turns the pause off, and on again.
  def test_the_checkbox_under_the_game_turns_the_pause_off
    assert_plays_frames(15, ["down KeyQ", "uncheck pause", "play 3", "blur", "play 10", "state", "focus", "play 2", "picture"],
                        %w[running])
    assert_plays_frames(5, ["uncheck pause", "check pause", "play 3", "blur", "play 10", "focus", "play 2", "picture"], [])
  end

  # The template decides how the pause starts: a page without the checkbox pauses, a checkbox
  # written without `checked` starts with it off, and a page that opens without the keyboard
  # waits for it before it plays a frame.
  def test_the_template_decides_whether_the_page_pauses
    away = ["play 3", "blur", "play 10", "focus", "play 2", "picture"]

    assert_plays_frames(5, away, [], template: "<%= game %>")
    assert_plays_frames(15, away, [], template: "<%= game %>\n<input type=\"checkbox\" id=\"pause\">")
    assert_plays_frames(2, ["play 10", "focus", "play 2", "picture"], [], focused: false)
  end

  # The pad on the screen plays the game as the keys do: a finger on the right of its cross is right
  # held.
  def test_a_finger_on_the_right_of_the_pads_cross_walks_like_the_arrow_key
    assert_walks_right_for_frames_two_to_eleven(["finger 1 pad-cross 1 0", "play 10", "picture", "lift 1", "play 5",
                                                 "picture"])
  end

  # Each of the pad's buttons is its console button, and a tap — on and off again between two
  # frames, as a quick finger is — still counts for the next frame.
  def test_a_tap_on_each_pad_button_presses_its_console_button
    on_cross = { right: "1 0", left: "-1 0", up: "0 -1", down: "0 1" }
    taps = RubyGBA::IR::Buttons::NAMES.flat_map do |button|
      ["finger 1 #{on_cross.key?(button) ? "pad-cross #{on_cross[button]}" : "pad-#{button}"}", "lift 1"]
    end
    picture = pictures_in(played_page([*taps, "play 2", "picture"], buttons_game)).first
    interpreter = Reference.new.input_each_frame { |frame| frame == 2 ? RubyGBA::IR::Buttons::NAMES : [] }
                           .run(buttons_game.program, frames: 2)

    assert_same_picture interpreter.screen.shown, picture, "on the frame after every button was tapped"
  end

  # The cross is one piece, as a console's is: a thumb rocked round it moves from one direction to
  # the next without lifting, holds two at once between them, and holds none at its middle.
  def test_a_thumb_rocked_round_the_cross_moves_from_one_direction_to_the_next
    assert_pad_holds(["1 0", "0.7 0.7", "0 1", "0 0"].map { |at| ["finger 1 pad-cross #{at}"] },
                     [%i[right], %i[right down], %i[down], []])
  end

  # Each finger holds what it is on now: one slid from B to A lets go of B, a second on A keeps A
  # held when the first lifts, and a finger slid off the pad, or taken back by the browser, holds
  # nothing.
  def test_each_finger_holds_what_it_is_on_until_it_lifts_or_slides_off
    assert_pad_holds([["finger 1 pad-b"], ["finger 1 pad-a", "finger 2 pad-cross 1 0"], ["finger 3 pad-a", "lift 1"],
                      ["cancel 2", "finger 3 nowhere"]],
                     [%i[b], %i[a right], %i[a right], []])
  end

  # The pad is for a screen whose main pointer is a finger: a phone shows it, and a computer with a
  # mouse has it hidden even when its screen can be touched too. A tablet that has its keyboard put
  # on or taken off shows or hides it then.
  def test_the_pad_shows_while_a_finger_is_the_screens_main_pointer
    shown = lambda do |steps, pointer|
      played_page([*steps, "text touchpad"], pointer: pointer).grep(/\Atext touchpad/).map { |line| !line.include?("hidden") }
    end

    assert_equal [true], shown.call([], :finger)
    assert_equal [false], shown.call([], :mouse)
    assert_equal [false], shown.call([], :touch_and_mouse)
    assert_equal [false, true, false], shown.call(["text touchpad", "pointer coarse", "text touchpad", "pointer fine"], :mouse)
  end

  # Each of +moves+ (the steps of one move of the fingers) is followed by two frames and a picture,
  # which is the interpreter's with the buttons in +held+ at that move's place held. The page reads
  # its buttons after each frame, for the next, so the first move, made before the page's first
  # frame, counts from frame 2, and each after it, made after an even frame, from the next but one.
  private def assert_pad_holds(moves, held)
    steps = moves.flat_map { |move| [*move, "play 2", "picture"] }
    pictures = pictures_in(played_page(steps, buttons_game))
    held.each_with_index do |buttons, i|
      frame = 2 + (2 * i)
      interpreter = Reference.new.input_each_frame { |f| f < 2 ? [] : held.fetch((f - 2) / 2, []) }
                             .run(buttons_game.program, frames: frame)
      assert_same_picture interpreter.screen.shown, pictures[i], "at frame #{frame}, with #{buttons.inspect} held"
    end
  end

  # +steps+ hold right from the page's start to frame 10 and take two pictures, at frames 10 and
  # 15: each is the interpreter's with right held for frames 2 to 11, since the page reads its
  # buttons after each frame, for the next.
  private def assert_walks_right_for_frames_two_to_eleven(steps, template: nil)
    walked, stood = pictures_in(played_page(steps, template: template))
    program = walking_game.program
    interpreter = ->(frames) { Reference.new.input_each_frame { |frame| (2..11).cover?(frame) ? [:right] : [] }.run(program, frames: frames) }

    assert_same_picture interpreter.call(10).screen.shown, walked, "at frame 10"
    assert_same_picture interpreter.call(15).screen.shown, stood, "at frame 15"
    refute_equal walked, stood, "the square moved on the frame after the button was read"
  end

  # A game that shows what the cartridge's clock says as one lit pixel a row, each as far along its
  # row as the reading: the minute, the hour, the day, the month, the year past 2000, and 1 on the
  # last row while the clock is there and set.
  private def clock_game
    RubyGBA.game "CLOCKED", consoles: %i[gba] do
      screen :bitmap
      now = clock
      game_loop do
        clear_screen :black
        [now.minute, now.hour, now.day, now.month, now.year - 2000].each_with_index do |reading, row|
          draw_rect_at reading, row * 10, 1, 1, :white
        end
        (now.present? & now.set?).then { draw_rect_at 1, 50, 1, 1, :white }
      end
    end
  end

  # THE PAGE'S CLOCK IS THE BROWSER'S, in its local time: the game is told there is a clock, that
  # it was set, and the date and the minute the computer says — at the start of the run or at its
  # end, should a minute turn over between the two. (The page's first frame is the game setting up
  # and shows nothing, so the picture read is the second's.)
  def test_the_page_reads_the_browsers_clock
    before = Time.now
    picture = pictures_in(played_page(["play 2", "picture"], clock_game)).first
    after = Time.now
    lit = (0..5).map { |row| picture[row * 10 * 240, 240].index { |color| color != 0 } }
    said = ->(time) { [time.min, time.hour, time.day, time.month, time.year - 2000] }

    assert_equal 1, lit.last, "the clock is there and set"
    assert_includes [said.call(before), said.call(after)], lit.first(5)
  end

  # A game that goes wrong stops where it is, and the page says why under the picture.
  def test_a_game_that_goes_wrong_says_so_under_the_picture
    game = RubyGBA.game "FULL", consoles: %i[gba] do
      screen :bitmap
      trail = list :trail, capacity: 2
      game_loop { trail.push 1 }
    end
    said = played_page(["play 5"], game).grep(/\Asaid /).first

    assert_match(/The game stopped: .*list :trail is full/, said)
  end
end
