# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test_hide_sprites.rb whose game shows a second background while another is showing,
# which a Game Boy Color's hardware cannot, so they play on the Advance's runs alone.
class TestHideSpritesOnTheAdvance < Minitest::Test
  include Differential

  HERO = [40, 40].freeze
  TEXT = [100, 40].freeze
  CALLED_ON = 5 # the pass that says hide_sprites

  # A red square and the word HI over scenery, in a game whose two screens use different layers:
  # a title with two backgrounds and play with one. The title has the screen for the first pass
  # only, so every frame around the call is play's.
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
    sprite :hero, at: TestHideSpritesOnTheAdvance::HERO
    draw_text "HI", *TestHideSpritesOnTheAdvance::TEXT, :white
    game_loop do
      passes.add! 1
      (passes > 1).then { set! :state, 1 }
      (passes == TestHideSpritesOnTheAdvance::CALLED_ON).then { hide_sprites }
      case_var(:state) do
        when_val 0, :title
        when_val 1, :play
      end
    end
  end

  private def program(source)
    b = Builder.new
    b.instance_eval(&source)
    b.finalize_program
    b.program
  end

  # Where each screen uses layers of its own, the screen in play sets its layers again on
  # every pass, and the sprites stay off all the same for the one frame asked.
  def test_sprites_hide_for_a_frame_where_each_screen_has_its_own_layers
    player = game_player
    seen = {}
    player.each_vblank { seen[player[:passes]] = player.screen.pixel(HERO[0] + 1, HERO[1] + 1) }
    player.run(program(SCENES), frames: CALLED_ON + 4)

    red = Color.resolve(:red)
    refute_equal red, seen.fetch(CALLED_ON + 1), "the hero is off on the frame after the call"
    assert_equal red, seen.fetch(CALLED_ON), "the hero shows before the call"
    assert_equal red, seen.fetch(CALLED_ON + 2), "the hero is back the frame after"
  end

  def test_the_console_hides_the_same_frame_where_each_screen_has_its_own_layers
    assert_backends_agree(program(SCENES), frames: 3..(CALLED_ON + 4), name: "HIDES")
  end
end
