# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/tower").to_s

# The tower example (examples/tower.rb): three floors, each a scene declaring its own :floor with
# a map, tiles and walls of its own, climbed by their stairs, and a gate on the roof that A opens.
# Played on every lowering, on the console each run plays a game as.
class TestTowerExample < Minitest::Test
  GRAY = Color.resolve(:gray)
  RED = Color.resolve(:red)
  ORANGE = Color.resolve(:orange)
  CYAN = Color.resolve(:cyan)
  BLUE = Color.resolve(:blue)
  YELLOW = Color.resolve(:yellow)
  WHITE = Color.resolve(:white)

  # A route is legs of [key, passes], each held until the hero is stopped by a wall and a few
  # passes over, so it is the walls that say where the hero ends up, not the count. A leg of nil
  # holds nothing.
  #
  # The ground floor: right to the far wall, then up to the top, onto the stairs in the corner.
  TO_GROUND_STAIRS = Ractor.make_shareable([[:right, 70], [:up, 62], [nil, 6]])

  # Upstairs: up through the doorway above the door to the wall across the floor, right along it
  # to the wall by the second doorway, then up through that onto the stairs.
  TO_UPSTAIRS_STAIRS = Ractor.make_shareable([[:up, 42], [:right, 70], [:up, 30], [nil, 6]])

  # The roof: right to the wall under the gate, then up toward it.
  UNDER_THE_GATE = Ractor.make_shareable([[:right, 40], [:up, 62]])

  # The player, holding each leg's key for its passes in turn, then nothing for +extra+ passes.
  private def played(legs, extra = 4)
    keys = legs.flat_map { |key, passes| [key] * passes }
    player = game_player
    frame = 0
    player.input_each_frame do
      key = keys[frame]
      frame += 1
      key ? [key] : []
    end
    player.run(Tower::GAME.program(console: game_console), frames: keys.length + extra)
  end

  # The colour of cell (+col+, +row+)'s middle.
  private def cell(screen, col, row) = screen.pixel((col * 8) + 4, (row * 8) + 4)

  def test_the_ground_floor_is_stone_with_its_own_walls
    shown = played([], 2).screen

    assert_equal GRAY, cell(shown, 0, 0), "a stone wall"
    assert_equal GRAY, cell(shown, 4, 5), "the ground floor's own inner wall"
  end

  def test_the_stairs_lead_to_a_wooden_floor_with_walls_of_its_own
    run = played(TO_GROUND_STAIRS)

    assert_equal 1, run[:level], "the hero climbed the ground floor's stairs"
    assert_equal RED, cell(run.screen, 0, 5), "upstairs is wood, with a wall across row 5"
    assert_equal ORANGE, cell(run.screen, 4, 4), "where the ground floor has a wall, upstairs has floor"
  end

  def test_the_second_stairs_lead_to_the_roof_and_a_opens_its_gate
    climbed = TO_GROUND_STAIRS + TO_UPSTAIRS_STAIRS
    shut = played(climbed + UNDER_THE_GATE)

    assert_equal 2, shut[:level], "the hero climbed both staircases"
    assert_equal CYAN, cell(shut.screen, 0, 8), "the roof's parapet"
    assert_equal YELLOW, cell(shut.screen, 9, 8), "the gate, shut"
    refute_equal WHITE, cell(shut.screen, 10, 1), "the shut gate held the hero back"

    opened = played(climbed + [[:a, 1]] + UNDER_THE_GATE)
    assert_equal BLUE, cell(opened.screen, 9, 8), "the gate, open"
    assert_equal WHITE, opened.screen.pixel(83, 9), "the hero walked through it to the top of the roof"
  end
end
