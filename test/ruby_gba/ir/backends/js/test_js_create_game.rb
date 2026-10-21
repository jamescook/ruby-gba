# frozen_string_literal: true

require "test_helper"
require "web_page"

# createGame(host): the game as something a page makes, as many times as it likes, rather than a
# script that starts itself. Every output of the web build — the page, the module, the classic
# script — is a caller of it. These pages are written by hand around JS#factory, as somebody's own
# page would be, and played in the stand-in browser (WebPage).
class TestJSCreateGame < Minitest::Test
  include WebPage
  JS = RubyGBA::IR::Backends::JS

  # A page of +canvases+ (their ids) that runs +host_js+ once createGame is defined. +host_js+
  # keeps what it makes in `games`, where a step can reach it (`js games[0].pause()`). With +data+
  # :separate, the game's big tables are to be fetched from game.data beside the page.
  private def page_of(game, canvases, host_js, data: :inline)
    factory, = JS.new.factory_and_data_file(game.program, title: game.title, data: data)
    <<~HTML
      <!doctype html>
      #{canvases.map { |id| %(<canvas id="#{id}" width="240" height="160"></canvas>) }.join("\n")}
      <script>
      (function () {
      "use strict";
      const rg_data_beside = "game.data";
      #{factory}
      #{host_js}
      })();
      </script>
    HTML
  end

  private def canvas(id) = %(document.getElementById("#{id}"))

  # Given nothing but a canvas, a game plays as the page plays it: the keyboard, the frames, the
  # picture.
  def test_a_host_given_only_a_canvas_plays_like_the_page
    html = page_of(walking_game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')} })];")
    mine = pictures_in(played_page(["down ArrowRight", "play 10", "picture one"], html: html)).first
    page = pictures_in(played_page(["down ArrowRight", "play 10", "picture"])).first

    assert_same_picture page, mine, "after ten frames holding right"
  end

  # Each createGame is a game of its own: two on one page keep their own state, and pausing one
  # leaves the other playing.
  def test_two_games_on_one_page_play_apart
    html = page_of(ticking_game, %w[one two],
                   "window.games = [createGame({ canvas: #{canvas('one')} }), createGame({ canvas: #{canvas('two')} })];")
    lines = played_page(["play 3", "js games[1].pause()", "play 5", "picture one", "picture two"], html: html)
    one, two = pictures_in(lines)
    eight, three = [8, 3].map { |frames| pictures_in(played_page(["play #{frames}", "picture"], ticking_game)).first }

    assert_same_picture eight, one, "of the game left playing"
    assert_same_picture three, two, "of the game paused after three frames"
  end

  # The handle presses the console's buttons by name, as a page's own on-screen pad would.
  def test_the_handle_presses_buttons_by_name
    html = page_of(walking_game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')} })];")
    pressed = pictures_in(played_page(['js games[0].press("right")', "play 10", "picture one"], html: html)).first
    keyed = pictures_in(played_page(["down ArrowRight", "play 10", "picture"])).first

    assert_same_picture keyed, pressed, "after ten frames with right pressed"
  end

  # A host can leave the keyboard alone: a page with a game of its own in a text editor's
  # neighbourhood, say.
  def test_a_host_can_turn_the_keyboard_off
    html = page_of(walking_game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')}, keys: false })];")
    still = pictures_in(played_page(["down ArrowRight", "play 10", "picture one"], html: html)).first
    untouched = pictures_in(played_page(["play 10", "picture"])).first

    assert_same_picture untouched, still, "with the keyboard off and right held"
  end

  # What the page says in words — a game that went wrong, a controller — goes to the host's
  # onMessage, which the page's own notes are one use of.
  def test_a_game_that_goes_wrong_tells_the_host
    game = RubyGBA.game "FULL", consoles: %i[gba] do
      screen :bitmap
      trail = list :trail, capacity: 2
      game_loop { trail.push 1 }
    end
    html = page_of(game, %w[one], <<~JS)
      window.said = [];
      window.games = [createGame({ canvas: #{canvas('one')}, onMessage: (kind, text) => said.push(`${kind}: ${text}`) })];
    JS
    told = played_page(["play 5", 'js said.join(" | ")'], html: html).grep(/\Ajs /).first

    assert_match(/stopped: The game stopped: .*list :trail is full/, told)
  end

  # A stopped game lets go of the page: its keys go back to the page (the arrows scroll again, F
  # does nothing), and a save not yet written is written as it stops.
  def test_a_stopped_game_lets_go_of_the_page_and_keeps_its_save
    game = RubyGBA.game "KEEPER", consoles: %i[gba] do
      screen :bitmap
      count = save_var :count, 0
      game_loop { count.add! 1 }
    end
    html = page_of(game, %w[one], <<~JS)
      window.kept = [];
      const storage = { getItem: () => null, setItem: (key) => kept.push(key) };
      window.games = [createGame({ canvas: #{canvas('one')}, storage })];
    JS
    lines = played_page(["play 3", "js games[0].stop()", "down ArrowRight", "down KeyF", "state", 'js kept.join(",")'], html: html)

    assert_includes lines, "state audio=none fullscreen=none kept=0"
    assert_includes lines, "js ruby-gba-save:KEEPER"
  end

  # The handle reads the save memory as it stands and writes it — a page's own "export my save" and
  # "import a save" — and refuses bytes that are not the size of the game's save memory.
  def test_the_handle_reads_and_writes_the_save
    game = RubyGBA.game "KEEPER", consoles: %i[gba] do
      screen :bitmap
      count = save_var :count, 0
      game_loop { count.add! 1 }
    end
    html = page_of(game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')}, storage: null })];")
    lines = played_page(["play 3", "js window.first = games[0].readSave(); first.length > 0 && first.some((byte) => byte !== 0xFF)",
                         "js games[0].writeSave(new Uint8Array(first.length).fill(7)); games[0].readSave().every((byte) => byte === 7)",
                         "js try { games[0].writeSave(new Uint8Array(3)); 'kept' } catch (error) { error.message }"], html: html)

    assert_equal ["js true", "js true"], lines.grep(/\Ajs /).first(2)
    assert_match(/must be \d+ bytes/, lines.grep(/\Ajs /).last)
  end

  # A click on a paused game makes the sound ready but keeps it waiting: it plays when the game does.
  def test_a_click_while_paused_keeps_the_sound_waiting
    html = page_of(ticking_game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')} })];")
    lines = played_page(["play 2", "blur", "click one", "state", "focus", "state"], html: html)

    assert_equal %w[suspended running], lines.grep(/\Astate /).map { |line| line[/audio=(\S+)/, 1] }
  end

  # Data given in a form the game cannot read is said to be that, in words that say what to give.
  def test_data_it_cannot_read_is_said_in_plain_words
    html = page_of(walking_game, %w[one], <<~JS, data: :separate)
      window.said = [];
      window.games = [createGame({ canvas: #{canvas('one')}, data: {}, onMessage: (kind, text) => said.push(text) })];
    JS
    told = played_page(["play 3", 'js said.join(" | ")'], html: html).grep(/\Ajs /).first

    assert_match(/cannot read the data.*address, or its bytes/, told)
  end

  # A host's own key layout takes the place of the window's: D is right here, and the arrows are
  # nothing.
  def test_a_host_can_lay_the_keys_out_its_own_way
    html = page_of(walking_game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')}, keyMap: { KeyD: \"right\" } })];")
    by_d = pictures_in(played_page(["down KeyD", "play 10", "picture one"], html: html)).first
    by_arrow = pictures_in(played_page(["down ArrowRight", "play 10", "picture one"], html: html)).first

    assert_same_picture walked_right, by_d, "with D held as right"
    assert_same_picture stood_still, by_arrow, "with the arrow held, which this layout leaves out"
  end

  # Keys heard on one element (a canvas given tabindex) are not heard on the rest of the page, so
  # two games on one page each hear only their own.
  def test_a_host_can_hear_keys_on_one_element_only
    html = page_of(walking_game, %w[one], "window.games = [createGame({ canvas: #{canvas('one')}, keyTarget: #{canvas('one')} })];")
    lines = played_page(["down ArrowRight", "play 10", "picture one", "state"], html: html)

    assert_same_picture stood_still, pictures_in(lines).first, "with right pressed elsewhere on the page"
    assert_includes lines, "state audio=none fullscreen=none kept=0"
  end

  # Turned off, the F key, controllers and sound are each left alone.
  def test_a_host_can_turn_off_the_f_key_controllers_and_sound
    html = page_of(walking_game, %w[one], <<~JS)
      window.said = [];
      window.games = [createGame({ canvas: #{canvas('one')}, fullscreenKey: null, gamepads: false, audio: false,
                                   onMessage: (kind, text) => said.push(kind) })];
    JS
    lines = played_page(["pad connect", "pad press 15", "down KeyF", "play 10", "picture one", "state", 'js said.join(",")'],
                        html: html)

    assert_same_picture stood_still, pictures_in(lines).first, "with the controller's right held and controllers off"
    assert_includes lines, "state audio=none fullscreen=none kept=0"
    refute_includes lines.grep(/\Ajs /).first.to_s, "controller"
  end

  # A game made with autostart false plays nothing until start, and then plays from its first
  # frame; ready settles once it can play.
  def test_a_host_can_start_the_game_when_it_chooses
    html = page_of(ticking_game, %w[one], <<~JS)
      window.games = [createGame({ canvas: #{canvas('one')}, autostart: false })];
      games[0].ready.then(() => { window.isReady = true; });
    JS
    lines = played_page(["play 5", "js games[0].start()", "play 4", "picture one", "js isReady"], html: html)
    four = pictures_in(played_page(["play 4", "picture"], ticking_game)).first

    assert_same_picture four, pictures_in(lines).first, "four frames after start, with five before it"
    assert_includes lines, "js true"
  end

  # The save is kept under the name the host gives, in place of the game's.
  def test_a_host_can_name_the_save
    game = RubyGBA.game "SAVER", consoles: %i[gba] do
      screen :bitmap
      count = save_var :count, 0
      count.add! 1
      halt
    end
    html = page_of(game, %w[one], <<~JS)
      window.kept = [];
      const storage = { getItem: () => null, setItem: (key) => kept.push(key) };
      window.games = [createGame({ canvas: #{canvas('one')}, storage, saveKey: "my-own-slot" })];
    JS

    assert_includes played_page(["play 3", 'js kept.join(",")'], html: html), "js my-own-slot"
  end

  private def walked_right = pictures_in(played_page(["down ArrowRight", "play 10", "picture"])).first
  private def stood_still = pictures_in(played_page(["play 10", "picture"])).first

  # The save goes where the host says, under the game's name unless the host names it.
  def test_the_save_goes_where_the_host_keeps_it
    game = RubyGBA.game "SAVER", consoles: %i[gba] do
      screen :bitmap
      count = save_var :count, 0
      count.add! 1
      halt
    end
    html = page_of(game, %w[one], <<~JS)
      window.kept = [];
      const storage = { getItem: () => null, setItem: (key, value) => kept.push(key) };
      window.games = [createGame({ canvas: #{canvas('one')}, storage })];
    JS

    assert_includes played_page(["play 3", 'js kept.join(",")'], html: html), "js ruby-gba-save:SAVER"
  end
end
