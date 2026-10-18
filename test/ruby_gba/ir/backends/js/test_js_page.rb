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
    walked, stood = pictures_in(played_page(["down ArrowRight", "play 10", "picture", "up ArrowRight", "play 5", "picture"]))
    program = walking_game.program
    interpreter = ->(frames) { Reference.new.input_each_frame { |frame| (2..11).cover?(frame) ? [:right] : [] }.run(program, frames: frames) }

    assert_equal interpreter.call(10).screen.shown, walked
    assert_equal interpreter.call(15).screen.shown, stood
    refute_equal walked, stood, "the square moved on the frame after the key was read"
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
