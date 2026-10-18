# frozen_string_literal: true

require "test_helper"
require "web_page"

# The web build's outputs other than its own page: the game as an ES module and as a classic
# script, each handing out createGame for a page of somebody else's — a framework's, a bundler's,
# a plain one. Each is played in the stand-in browser (WebPage) from a page written by hand, as
# that somebody would write it, and has to play as the web build's own page does.
class TestJSOutputs < Minitest::Test
  include WebPage
  JS = RubyGBA::IR::Backends::JS

  # The file +build+ writes for the walking game, read back.
  private def built(name)
    Dir.mktmpdir do |dir|
      path = File.join(dir, name)
      yield path
      File.read(path, encoding: Encoding::UTF_8)
    end
  end

  private def walked_on_the_page = pictures_in(played_page(["down ArrowRight", "play 10", "picture"])).first

  # The module exports createGame (as its default too) and the game's title, and a page that
  # imports it plays the game as the web build's own page does.
  def test_the_module_hands_out_create_game
    mjs = built("game.mjs") { |path| JS.new.build_module(walking_game, path, err: nil) }
    html = <<~HTML
      <!doctype html>
      <canvas id="one" width="240" height="160"></canvas>
      <script type="module">
      import makeGame, { createGame, title } from "./game.mjs";
      window.games = [createGame({ canvas: document.getElementById("one") })];
      window.facts = [title, makeGame === createGame];
      </script>
    HTML
    lines = played_page(["down ArrowRight", "play 10", "picture one", 'js facts.join(",")'], html: html, beside: { "game.mjs" => mjs })

    assert_same_picture walked_on_the_page, pictures_in(lines).first, "of the module's game after ten frames holding right"
    assert_includes lines, "js PAGE <&>,true"
  end

  # A square walked along 300 places kept in a table — big enough to go to the data file when the
  # data is separate — so the picture is wrong if the table is.
  private def table_walker
    RubyGBA.game "TABLED" do
      screen :bitmap
      places = table :places, (0...300).map { |i| (i * 7) % 200 }, width: :half
      n = var :n, 0
      game_loop do
        n.add! 1
        clear_screen :black
        draw_rect_at places[n], 20, 4, 4, :green
      end
    end
  end

  # +game+ as a module with its big tables in a data file, as { "game.mjs" => text, "game.data" => bytes }.
  private def module_and_data(game)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "game.mjs")
      JS.new.build_module(game, path, data: :separate, err: nil)
      { "game.mjs" => File.read(path, encoding: Encoding::UTF_8), "game.data" => File.binread(File.join(dir, "game.data")) }
    end
  end

  private def module_page(host = "", before: "")
    <<~HTML
      <!doctype html>
      <canvas id="one" width="240" height="160"></canvas>
      <script type="module">
      import { createGame } from "./game.mjs";
      #{before}
      window.said = [];
      window.games = [createGame({ canvas: document.getElementById("one"), onMessage: (kind, text) => said.push(text)#{host} })];
      </script>
    HTML
  end

  # With the data separate, the big table is in the data file and not in the module, the module
  # fetches it from beside itself before the first frame, and the game plays as it does with the
  # data inline.
  def test_a_module_with_separate_data_plays_as_with_it_inline
    files = module_and_data(table_walker)
    inline = pictures_in(played_page(["play 12", "picture"], table_walker)).first
    separate = pictures_in(played_page(["play 12", "picture one"], html: module_page, beside: files)).first

    refute_match(/= rg_table_from_base64\(/, files["game.mjs"], "the big table is not in the module")
    assert_same_picture inline, separate, "with the data fetched from its own file"
  end

  # The page and the classic script take their data separate too, each finding it beside itself.
  def test_the_page_and_the_script_with_separate_data_play_as_with_it_inline
    inline = pictures_in(played_page(["play 12", "picture"], table_walker)).first
    page, page_data = Dir.mktmpdir do |dir|
      JS.new.build_page(table_walker, File.join(dir, "game.html"), data: :separate, err: nil)
      [File.read(File.join(dir, "game.html")), File.binread(File.join(dir, "game.data"))]
    end
    script, script_data = Dir.mktmpdir do |dir|
      JS.new.build_script(table_walker, File.join(dir, "game.js"), data: :separate, err: nil)
      [File.read(File.join(dir, "game.js")), File.binread(File.join(dir, "game.data"))]
    end
    script_page = <<~HTML
      <!doctype html>
      <canvas id="one" width="240" height="160"></canvas>
      <script>
      #{script}
      window.games = [RubyGBA.game.createGame({ canvas: document.getElementById("one") })];
      </script>
    HTML

    assert_same_picture inline, pictures_in(played_page(["play 12", "picture"], html: page, beside: { "game.data" => page_data })).first,
                        "of the page with its data separate"
    assert_same_picture inline, pictures_in(played_page(["play 12", "picture one"], html: script_page,
                                                                                    beside: { "game.data" => script_data })).first,
                        "of the script with its data separate"
  end

  # A host that has the data already — a bundler that imports it as bytes — hands it over, and
  # nothing is fetched.
  def test_a_host_can_hand_over_the_data
    files = module_and_data(table_walker)
    html = module_page(", data: bytes", before: "const bytes = new Uint8Array([#{files['game.data'].bytes.join(',')}]);")
    inline = pictures_in(played_page(["play 12", "picture"], table_walker)).first
    handed = pictures_in(played_page(["play 12", "picture one"], html: html, beside: files.except("game.data"))).first

    assert_same_picture inline, handed, "with the data handed over"
  end

  # A data file that is not there, or is from another build of the game, stops the game before it
  # starts, saying which — never a game played on the wrong numbers.
  def test_missing_or_mismatched_data_stops_the_game_in_plain_words
    files = module_and_data(table_walker)
    # Another build's data file starts with another build's fingerprint.
    stale = files.merge("game.data" => files["game.data"].b.tap { |bytes| bytes.setbyte(0, bytes.getbyte(0) ^ 1) })

    missing = played_page(["play 3", 'js said.join(" | ")'], html: module_page, beside: files.except("game.data"))
    mismatched = played_page(["play 3", 'js said.join(" | ")'], html: module_page, beside: stale)

    assert_match(/could not load .*game\.data/i, missing.grep(/\Ajs /).first)
    assert_match(/not the one this build of the game/i, mismatched.grep(/\Ajs /).first)
  end

  # The classic script puts createGame and the title on window.RubyGBA under the name it is given
  # (the file's own name unless told), beside any other game's, and leaves nothing else behind.
  # A page loads it with a script tag; here it is written into the page, which runs it the same.
  def test_the_classic_script_puts_create_game_on_a_global
    walker = built("walker.js") { |path| JS.new.build_script(walking_game, path, err: nil) }
    ticker = built("t.js") { |path| JS.new.build_script(ticking_game, path, name: "ticker", err: nil) }
    html = <<~HTML
      <!doctype html>
      <canvas id="one" width="240" height="160"></canvas>
      <script>
      #{walker}
      #{ticker}
      window.games = [RubyGBA.walker.createGame({ canvas: document.getElementById("one") })];
      window.facts = [RubyGBA.walker.title, RubyGBA.ticker.title, typeof createGame, typeof page_create];
      </script>
    HTML
    lines = played_page(["down ArrowRight", "play 10", "picture one", 'js facts.join(",")'], html: html)

    assert_same_picture walked_on_the_page, pictures_in(lines).first, "of the script's game after ten frames holding right"
    assert_includes lines, "js PAGE <&>,TICKING,undefined,undefined"
  end
end
