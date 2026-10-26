# frozen_string_literal: true

require "test_helper"

# The tests of test_blocks.rb whose games show the screen in blocks, which a Game Boy Color's
# hardware cannot do, so they play on the Advance's runs alone.
class TestBlocksOnTheAdvance < Minitest::Test
  include VBlank::IR::Build

  def test_a_program_with_one_place_is_run_by_both
    one_place = program(screen(:tiled), layers(%i[world ui]),
                        pixelate(size: int(4), under: :ui), pixelate(size: int(9), under: :ui), halt)

    game_player.run(one_place)

    refute_empty GBA.new.lower(one_place)
  end
end
