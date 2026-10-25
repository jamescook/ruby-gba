# frozen_string_literal: true

require "test_helper"
require "differential"

# EVERY SPRITE OFF FOR A FRAME. A game that changes a lot at once — a room loading behind a
# fade, a map opening — can keep every sprite off the screen for the one frame where some of
# them are not where they will be yet, without touching any of them: on a tiled screen the
# text is sprites too, and it goes with them. The frame after, everything shows where it
# would have.
class TestHideSprites < Minitest::Test
  include Differential

  Fonts = RubyGBA::Graphics::Fonts

  CALLED_ON = 3 # the pass that says hide_sprites
  HERO = [40, 40].freeze
  TEXT = [100, 40].freeze

  # A red square, the word HI, and a counter of passes.
  GAME = proc do
    screen :tiled
    image :hero, "#" => :red do
      Array.new(8) { "#" * 8 }.join("\n")
    end
    passes = var :passes, 0
    sprite :hero, at: TestHideSprites::HERO
    draw_text "HI", *TestHideSprites::TEXT, :white
    game_loop do
      passes.add! 1
      (passes == TestHideSprites::CALLED_ON).then { hide_sprites }
    end
  end

  # The same over scenery, in a game whose two screens use different layers: a title with two
  # backgrounds and play with one. The title has the screen for the first pass only, so
  # every frame around the call is play's.
  SCENES = proc do
    screen :tiled
    image :hero, "#" => :red do
      Array.new(8) { "#" * 8 }.join("\n")
    end
    image(:sea_art, "#" => :blue) { Array.new(8) { "#" * 8 }.join("\n") }
    tiles :sea, "#" => :sea_art
    map = Array.new(20) { "#" * 30 }
    scene(:title) do
      background :far, tiles: :sea, map: map
      background :near, tiles: :sea, map: map
    end
    scene(:play) { background :field, tiles: :sea, map: map }
    passes = var :passes, 0
    var :state, 0
    sprite :hero, at: TestHideSprites::HERO
    draw_text "HI", *TestHideSprites::TEXT, :white
    game_loop do
      passes.add! 1
      (passes > 1).then { set! :state, 1 }
      (passes == TestHideSprites::CALLED_ON_IN_PLAY).then { hide_sprites }
      case_var(:state) do
        when_val 0, :title
        when_val 1, :play
      end
    end
  end

  CALLED_ON_IN_PLAY = 5

  private def program(source)
    b = Builder.new
    b.instance_eval(&source)
    b.finalize_program
    b.program
  end

  # The first lit pixel of the glyph for H, where the text is drawn.
  private def text_pixel
    Fonts.get(:default).each_pixel("H") { |dx, dy| return [TEXT[0] + dx, TEXT[1] + dy] }
  end

  # The sprites are drawn in the gap after each pass, so the picture seen while +passes+ is n
  # was drawn from pass n - 1: the frame drawn after the pass that says hide_sprites is the one
  # seen while passes is one past it.
  def test_the_frame_after_the_call_shows_no_sprite_and_the_next_shows_them_all
    player = game_player
    seen = {}
    player.each_vblank do
      passes = player[:passes]
      seen[passes] = [player.screen.pixel(HERO[0] + 1, HERO[1] + 1), player.screen.pixel(*text_pixel)] if passes >= 2
    end
    player.run(program(GAME), frames: CALLED_ON + 4)

    red = Color.resolve(:red)
    white = Color.resolve(:white)
    seen.each do |passes, (hero, text)|
      if passes == CALLED_ON + 1
        refute_equal red, hero, "the hero is off on the frame after the call"
        refute_equal white, text, "the text is off on the frame after the call"
      else
        assert_equal red, hero, "the hero shows while passes is #{passes}"
        assert_equal white, text, "the text shows while passes is #{passes}"
      end
    end
    assert_includes seen.keys, CALLED_ON + 1
    assert_includes seen.keys, CALLED_ON + 2
  end

  # On the console the sprite layer goes off for that one frame and comes back on the next:
  # every pixel of every frame around the call is the interpreter's.
  def test_the_console_hides_the_same_frame
    assert_backends_agree(program(GAME), frames: 2..(CALLED_ON + 4), name: "HIDE")
  end

  # Where each screen uses layers of its own, the screen in play sets its layers again on
  # every pass, and the sprites stay off all the same for the one frame asked.
  def test_sprites_hide_for_a_frame_where_each_screen_has_its_own_layers
    player = game_player
    seen = {}
    player.each_vblank { seen[player[:passes]] = player.screen.pixel(HERO[0] + 1, HERO[1] + 1) }
    player.run(program(SCENES), frames: CALLED_ON_IN_PLAY + 4)

    red = Color.resolve(:red)
    refute_equal red, seen.fetch(CALLED_ON_IN_PLAY + 1), "the hero is off on the frame after the call"
    assert_equal red, seen.fetch(CALLED_ON_IN_PLAY), "the hero shows before the call"
    assert_equal red, seen.fetch(CALLED_ON_IN_PLAY + 2), "the hero is back the frame after"
  end

  def test_the_console_hides_the_same_frame_where_each_screen_has_its_own_layers
    assert_backends_agree(program(SCENES), frames: 3..(CALLED_ON_IN_PLAY + 4), name: "HIDES")
  end
end
