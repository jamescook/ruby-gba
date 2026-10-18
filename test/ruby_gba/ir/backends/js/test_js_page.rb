# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# A game built for the web is one page: the picture's canvas, the keys said in words, and the game
# and its runtime in one script, with nothing fetched — so the page opens from a disk. Its script
# is played here in node with a stand-in for the browser (page_harness.js), so what is checked is
# the page's own driver: the keys it reads, the frames it plays and the picture it puts up.
class TestJSPage < Minitest::Test
  JS = RubyGBA::IR::Backends::JS
  HARNESS = File.join(__dir__, "page_harness.js")

  # Right moves the square, a pixel a frame.
  private def walking_game
    RubyGBA.game "PAGE <&>" do
      screen :bitmap
      x = var :x, 0
      game_loop do
        held(:right).then { x.add! 1 }
        clear_screen :black
        draw_rect_at x, 20, 4, 4, :green
      end
    end
  end

  # +game+'s page, written by the default template or by one whose text is +template+.
  private def built_page(game = walking_game, template: nil)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "page.html")
      options = {}
      if template
        options[:page] = File.join(dir, "page.html.erb")
        File.write(options[:page], template)
      end
      JS.new.build_page(game, path, err: nil, **options)
      File.read(path, encoding: Encoding::UTF_8)
    end
  end

  # What the harness printed for +steps+ (one a line, see page_harness.js), played on +game+'s page.
  # +focused+ false starts the window without the keyboard, as a page in a frame on another site.
  private def played_page(steps, game = walking_game, template: nil, focused: true)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "page.html")
      File.write(path, built_page(game, template: template))
      out, said, status = Open3.capture3("node", HARNESS, path, *("unfocused" unless focused),
                                         stdin_data: steps.join("\n"))
      assert status.success?, said
      out.lines(chomp: true)
    end
  end

  private def pictures_in(lines) = lines.grep(/\Apicture /).map { |line| line.split(" ", 2).last.split(",").map(&:to_i) }

  def test_the_page_holds_the_canvas_and_the_whole_game
    page = built_page

    assert_match(/<canvas id="screen" width="240" height="160">/, page)
    assert_match(/<title>PAGE &lt;&amp;&gt;<\/title>/, page, "the title is said as text, not as markup")
    assert_match(/function\* rg_game_main\(\)/, page)
    assert_match(/function rg_driver_start\(\)/, page)
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
    buttons = %i[a b select start right left up down r l]
    game = RubyGBA.game "BUTTONS" do
      screen :bitmap
      game_loop do
        clear_screen :black
        buttons.each_with_index { |button, i| held(button).then { fill_rect i * 10, 0, 8, 8, :white } }
      end
    end
    picture = pictures_in(played_page(["pad connect", *[0, 1, 8, 9, 5, 4].map { |n| "pad press #{n}" },
                                       "down ArrowRight", "play 3", "picture"], game)).first
    held = %i[a b select start r l right]
    interpreter = Reference.new.input_each_frame { |frame| frame >= 2 ? held : [] }.run(game.program, frames: 3)

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
  # it says nothing. Losing the keyboard again lets go of every key, which may come up elsewhere.
  def test_a_page_without_the_keyboard_says_to_click_and_lets_go_of_keys_when_it_loses_it
    lines = played_page(["play 1", "text said", "focus", "down ArrowRight", "play 3", "text said", "blur",
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
                         "down KeyF meta", "state"])

    assert_equal %w[screen none screen screen], lines.grep(/\Astate /).map { |line| line[/fullscreen=(\S+)/, 1] }
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

  # Two pictures the same, or a failure saying how many pixels differ and where the first is,
  # rather than both screens in full.
  private def assert_same_picture(want, got, moment)
    differ = want.each_index.reject { |i| want[i] == got[i] }
    first = differ.first
    assert_empty differ, "the page's picture #{moment} differs from the interpreter's at #{differ.size} pixels, " \
                         "first at (#{first.to_i % 240}, #{first.to_i / 240})"
  end

  # A game that goes wrong stops where it is, and the page says why under the picture.
  def test_a_game_that_goes_wrong_says_so_under_the_picture
    game = RubyGBA.game "FULL" do
      screen :bitmap
      trail = list :trail, capacity: 2
      game_loop { trail.push 1 }
    end
    said = played_page(["play 5"], game).grep(/\Asaid /).first

    assert_match(/The game stopped: .*list :trail is full/, said)
  end
end
