# frozen_string_literal: true

require "test_helper"
require "differential"

# A SEE-THROUGH LAYER GIVEN TWO AMOUNTS: how much of ITSELF shows, and how much of what is
# BEHIND it. `transparency:` splits one whole between the two; these need not add to one,
# and a sum past a whole comes out brighter than either side and stops at full brightness —
# which is how a window glows over a backdrop, or a shaft of light brightens a forest.
#
# The console mixes in sixteenths, so an amount is rounded to the nearest one: 94 is 15/16
# and 63 is 10/16, the pair a retail cartridge's file-select window is drawn with.
class TestLayerTwoAmounts < Minitest::Test
  include Differential

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # Two columns of floor under a pane: on the left a dim pane over a dim floor, where
  # nothing reaches full brightness; on the right white over red, where red and green
  # both run past it.
  def pane_program(shows:, behind:)
    tile = SOLID_TILE
    program do
      screen :tiled
      image(:dim_floor, "#" => rgb(20, 4, 30)) { tile }
      image(:red_floor, "#" => :red) { tile }
      image(:dim_pane, "#" => rgb(16, 8, 2)) { tile }
      image(:white_pane, "#" => :white) { tile }
      tiles :floors, "d" => :dim_floor, "r" => :red_floor
      tiles :panes, "d" => :dim_pane, "w" => :white_pane
      layers :deep, :glass
      layer(:deep) { background :floor, tiles: :floors, map: Array.new(20) { ("d" * 15) + ("r" * 15) } }
      layer(:glass, shows: shows, shows_behind: behind) do
        background :pane, tiles: :panes, map: Array.new(20) { ("d" * 15) + ("w" * 15) }
      end
      game_loop { wait_vblank }
    end
  end

  def rgb5(r, g, b) = r | (g << 5) | (b << 10)

  # Each channel is (pane x 15 + floor x 10) / 16, the sixteenth dropped once, worked in
  # eight bits the way the emulator mixes (16 is 132, 20 is 165, 31 is 255) and taken back
  # to five. Measured on the console, where the five-bit sum gives (27, 10, 20).
  DIM = [8, 8].freeze
  # (132*15 + 165*10) / 16 = 226 -> 28, (66*15 + 33*10) / 16 = 82 -> 10, (16*15 + 247*10) / 16 = 169 -> 21
  DIM_MIXED = [28, 10, 21].freeze
  BRIGHT = [200, 8].freeze
  # red: 255*25/16 is past full, so 31; green and blue: 255*15/16 = 239 -> 29
  BRIGHT_MIXED = [31, 29, 29].freeze

  def test_a_layer_can_show_itself_and_what_is_behind_by_amounts_of_their_own
    screen = Reference.new.run(pane_program(shows: 94, behind: 63), frames: 2).screen

    assert_equal rgb5(*DIM_MIXED), screen.pixel(*DIM)
    assert_equal rgb5(*BRIGHT_MIXED), screen.pixel(*BRIGHT), "past a whole, a channel stops at full"
  end

  def test_the_console_mixes_them_the_same_way
    oracle, console, = backend_pictures(pane_program(shows: 94, behind: 63), frames: 2)

    assert_equal rgb5(*DIM_MIXED), console[(DIM[1] * 240) + DIM[0]]
    assert_equal rgb5(*BRIGHT_MIXED), console[(BRIGHT[1] * 240) + BRIGHT[0]]
    assert_empty mismatched_pixels(oracle, console)
  end
end
