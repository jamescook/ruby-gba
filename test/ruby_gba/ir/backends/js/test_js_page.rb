# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# A game built for the web is one page: the picture's canvas, the keys said in words, and the game
# and its runtime in one script, with nothing fetched — so the page opens from a disk.
class TestJSPage < Minitest::Test
  JS = RubyGBA::IR::Backends::JS

  private def built_page
    game = RubyGBA.game "PAGE <&>" do
      screen :bitmap
      x = var :x, 0
      game_loop do
        held(:right).then { x.add! 1 }
        clear_screen :black
        draw_rect_at x, 20, 4, 4, :green
      end
    end
    Dir.mktmpdir do |dir|
      path = File.join(dir, "page.html")
      JS.new.build_page(game, path, err: nil)
      File.read(path, encoding: Encoding::UTF_8)
    end
  end

  def test_the_page_holds_the_canvas_and_the_whole_game
    page = built_page

    assert_match(/<canvas id="screen" width="240" height="160">/, page)
    assert_match(/<title>PAGE &lt;&amp;&gt;<\/title>/, page, "the title is said as text, not as markup")
    assert_match(/function\* rg_game_main\(\)/, page)
    assert_match(/function rg_driver_start\(\)/, page)
    refute_match(/<script src=/, page)
  end

  # The script is one a browser can run: it parses, with every runtime file and the game in it.
  def test_the_pages_script_parses
    script = built_page[%r{<script>\n(.*)</script>}m, 1]
    Dir.mktmpdir do |dir|
      path = File.join(dir, "page.js")
      File.write(path, script)
      _, said, status = Open3.capture3("node", "--check", path)

      assert status.success?, said
    end
  end
end
