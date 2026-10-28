# frozen_string_literal: true

require "test_helper"

# A BACKGROUND FADED THROUGH MANY LISTS OF COLOURS keeps a table for every step it can show: what
# each of its palettes holds there, for every screen that says `draw_with`. Screens of
# eight palettes stepped through forty lists come to more than the part of a
# Color cartridge always in view holds beside the game's code. Such a game is built with those
# tables in the cartridge's banks (GBC#build_cartridge), read with their bank put in view, and
# plays as it does on the interpreter.
class TestGBCBankedColors < Minitest::Test
  TILES = 8
  STEPS = 40
  PLACES = 6

  private def many_fades
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      steps = (0...TILES).to_h do |t|
        colors :"own#{t}", [:transparent, rgb(31, t * 3, 0), rgb(0, 31, t * 3), rgb(t * 3, 0, 31)]
        image :"tile#{t}", width: 8, height: 8, colors: :"own#{t}", places: Array.new(64) { |i| 1 + ((i / 8) % 3) }
        lists = (0...STEPS).map do |s|
          colors :"step#{t}_#{s}", [:transparent, rgb(s % 32, t * 3, 31 - (s % 32)), rgb(t * 3, s % 32, 9), rgb(9, 31 - (s % 32), t * 3)]
          :"step#{t}_#{s}"
        end
        [:"own#{t}", lists]
      end
      tiles :set, (0...TILES).to_h { |t| [t.to_s, :"tile#{t}"] }
      step = var :step, 0
      state = var :state, 0
      PLACES.times do |place|
        scene(:"screen#{place}") do
          field = background :"field#{place}", tiles: :set, map: Array.new(18) { (0...TILES).map(&:to_s).join * 3 }
          field.draw_with steps, showing: step
        end
      end
      game_loop do
        step.set!((step + 1) % STEPS)
        (step == 0).then { state.set!((state + 1) % PLACES) }
        case_var(:state) { PLACES.times { |place| when_val place, :"screen#{place}" } }
      end
    end
    b.finalize_program
    b.program
  end

  def test_the_colour_tables_go_in_the_banks_when_they_do_not_fit_in_view
    built = VBlank::IR::Backends::GBC.new.build(many_fades, title: "FADES").built

    assert built.code.key?("rt_background_colors_far"), "the tables are read with their bank put in view"
  end

  def test_a_screen_whose_colour_tables_do_not_fit_in_view_still_builds_and_plays
    # Forty steps a screen, so the run fades through the first three screens.
    game_player.run(many_fades, frames: (STEPS * 2) + 10)
  end
end
