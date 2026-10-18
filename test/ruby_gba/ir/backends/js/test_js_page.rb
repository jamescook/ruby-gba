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

  private def built_page(game = walking_game)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "page.html")
      JS.new.build_page(game, path, err: nil)
      File.read(path, encoding: Encoding::UTF_8)
    end
  end

  private def page_script(game = walking_game) = built_page(game)[%r{<script>\n(.*)</script>}m, 1]

  # What the harness printed for +steps+ (one a line, see page_harness.js), played on +game+'s page.
  private def played_page(steps, game = walking_game)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "page.js")
      File.write(path, page_script(game))
      out, said, status = Open3.capture3("node", HARNESS, path, stdin_data: steps.join("\n"))
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

  # +steps+ hold right from the page's start to frame 10 and take two pictures, at frames 10 and
  # 15: each is the interpreter's with right held for frames 2 to 11, since the page reads its
  # buttons after each frame, for the next.
  private def assert_walks_right_for_frames_two_to_eleven(steps)
    walked, stood = pictures_in(played_page(steps))
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
