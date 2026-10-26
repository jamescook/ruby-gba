# frozen_string_literal: true

require "test_helper"
require "differential"
require "tinted_handover"

# A tint left on while the game changes screen. The plain bitmap screen holds a whole colour
# in every pixel and has the display mix the tint in as it draws; the tear-free bitmap screen
# and a tiled one draw every pixel through a colour table, so there the tint is the table
# moved. The tint is one thing to the game, so it has to survive the change whichever way
# round it goes, on every backend, and be mixed the way the new screen mixes it.
class TestTintAcrossScreens < Minitest::Test
  include Differential
  include TintedHandover

  private def program(&body)
    b = VBlank::Builder.new
    b.instance_eval(&body)
    b.finalize_program
    b.program
  end

  GREEN = 0x03E0
  HALF_RED = 0x01EF # green half way to red

  PAIRS = [%i[plain tiled], %i[tiled plain], %i[plain tear_free], %i[tear_free plain],
           %i[tear_free tiled], %i[tiled tear_free]].freeze

  def test_a_tint_stays_on_from_one_screen_to_another
    PAIRS.each do |from, to|
      handover = tinted_handover(from, to)

      assert_backends_agree(handover, frames: 10, console_frames: 12, name: "TTO")
      assert_equal HALF_RED, shown_after_handover(handover), "from #{from} to #{to}"
    end
  end

  def test_a_tint_the_game_works_out_stays_on
    %i[plain tiled].permutation.each do |from, to|
      handover = tinted_handover(from, to, amount: :worked_out)

      assert_backends_agree(handover, frames: 10, console_frames: 12, name: "TWORK")
      assert_equal HALF_RED, shown_after_handover(handover), "from #{from} to #{to}"
    end
  end

  # A fade takes the tint's place, so a fade back to the picture as drawn leaves nothing to
  # bring back on the next screen.
  def test_a_fade_after_the_tint_leaves_nothing_to_bring_back
    %i[plain tiled].permutation.each do |from, to|
      handover = tinted_handover(from, to) { fade :black, 0 }

      assert_backends_agree(handover, frames: 10, console_frames: 12, name: "TFADE")
      assert_equal GREEN, shown_after_handover(handover), "from #{from} to #{to}"
    end
  end

  # Lifted on one screen, it stays lifted on the next.
  def test_a_tint_lifted_stays_lifted
    %i[plain tiled].permutation.each do |from, to|
      handover = tinted_handover(from, to) { tint :red, 0 }

      assert_backends_agree(handover, frames: 10, console_frames: 12, name: "TLIFT")
      assert_equal GREEN, shown_after_handover(handover), "from #{from} to #{to}"
    end
  end

  # A fade the display holds stays on through the change, whatever the tint did before it.
  def test_a_fade_held_by_the_display_stays_on
    %i[plain tiled].permutation.each do |from, to|
      handover = tinted_handover(from, to) { fade :black, 50 }

      assert_backends_agree(handover, frames: 10, console_frames: 12, name: "THELD")
      refute_equal GREEN, shown_after_handover(handover), "from #{from} to #{to}"
    end
  end

  # A redout that has settled is a tint nothing says again, so only what the game keeps
  # carries it to the next screen.
  RED = 0x001F

  def test_a_settled_redout_stays_red_on_the_next_screen
    %i[plain tiled].permutation.each do |from, to|
      handover = tinted_handover(from, to, amount: 0) { fade_out :red, frames: 2 }

      assert_backends_agree(handover, frames: 10, console_frames: 12, name: "TREDOUT")
      assert_equal RED, shown_after_handover(handover), "from #{from} to #{to}"
    end
  end

  # A game that boots on a painted screen and fires a coloured flash while a tiled scene is
  # up. The flash is walked by a routine of its own every frame, wherever the game is.
  private def flash_on_tiles
    tile = SOLID_TILE
    program do
      screen :bitmap
      image(:ground, "#" => :green) { tile }
      tiles :grass, "#" => :ground
      state = var :state, 0
      ticks = var :ticks, 0
      scene :painted do
        clear_screen :green
      end
      scene :tiles do
        screen :tiled
        background :floor, tiles: :grass, map: Array.new(20) { "#" * 30 }
      end
      game_loop do
        ticks.add! 1
        (ticks == 3).then { state.set! 1 }
        (ticks == 8).then { flash_screen :red, frames: 12 }
        case_var(:state) do
          when_val 0, :painted
          when_val 1, :tiles
        end
      end
    end
  end

  def test_a_coloured_flash_on_a_tiled_scene_of_a_painted_game
    assert_backends_agree(flash_on_tiles, frames: 10, console_frames: 12, name: "FLASH")
    assert_equal 0x007B, game_player.run(flash_on_tiles, frames: 10).screen.pixel(120, 80) # red on its way back to green
  end
end
