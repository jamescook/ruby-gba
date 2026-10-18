# frozen_string_literal: true

require "open3"
require "tmpdir"

# A web build's page, played in node with a stand-in for the browser
# (test/ruby_gba/ir/backends/js/page_harness.js, which says what each step does), and the two
# small games the page's tests play on it. `include WebPage` in a test of the page or of
# createGame.
module WebPage
  HARNESS = RubyGBA.root.join("test", "ruby_gba", "ir", "backends", "js", "page_harness.js").to_s

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

  # The square moves a pixel every frame, so the picture says how many frames were played.
  private def ticking_game
    RubyGBA.game "TICKING" do
      screen :bitmap
      x = var :x, 0
      game_loop do
        x.add! 1
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
      RubyGBA::IR::Backends::JS.new.build_page(game, path, err: nil, **options)
      File.read(path, encoding: Encoding::UTF_8)
    end
  end

  # What the harness printed for +steps+ (one a line), played on +game+'s page — or on +html+, a
  # page written by hand, with +beside+ ({ name => text }) the files it loads from beside it.
  # +focused+ false starts the window without the keyboard, as a page in a frame on another site.
  private def played_page(steps, game = walking_game, template: nil, focused: true, html: nil, beside: {})
    Dir.mktmpdir do |dir|
      path = File.join(dir, "page.html")
      File.write(path, html || built_page(game, template: template))
      beside.each { |name, text| File.binwrite(File.join(dir, name), text) }
      out, said, status = Open3.capture3("node", HARNESS, path, *("unfocused" unless focused),
                                         stdin_data: steps.join("\n"))
      assert status.success?, said
      out.lines(chomp: true)
    end
  end

  private def pictures_in(lines) = lines.grep(/\Apicture /).map { |line| line.split(" ", 2).last.split(",").map(&:to_i) }

  # Two pictures the same, or a failure saying how many pixels differ and where the first is,
  # rather than both screens in full.
  private def assert_same_picture(want, got, moment)
    differ = want.each_index.reject { |i| want[i] == got[i] }
    first = differ.first
    assert_empty differ, "the page's picture #{moment} differs from the one expected at #{differ.size} pixels, " \
                         "first at (#{first.to_i % 240}, #{first.to_i / 240})"
  end
end
