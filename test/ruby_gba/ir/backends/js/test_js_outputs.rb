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
end
