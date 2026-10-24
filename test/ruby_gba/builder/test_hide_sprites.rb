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
end
