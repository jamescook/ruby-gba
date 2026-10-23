# frozen_string_literal: true

require "test_helper"
require "differential"
require "midpoint_circle"

# The tests of test_spotlight_shape.rb whose games have a light, which darkens everything outside a
# circle, and a Game Boy Color's hardware cannot, so they play on the Advance's runs alone.
class TestSpotlightShapeOnTheAdvance < Minitest::Test
  include Differential
  include MidpointCircle

  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A room drawn all in white, with a light at (120, 80) and +said+ run before the loop.
  private def lit_room(radius: 40, dark: 100, &said)
    program do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      light = spotlight at: [120, 80], radius: radius, dark: dark
      instance_exec(light, &said) if said
      game_loop {}
    end
  end

  private def shown(program, frames: 2) = game_player.run(program, frames: frames).screen

  # A DIAMOND, said as how far the light reaches either side of its middle on each row: 40 on the
  # middle row, one less for each row away, nothing past 40 rows.
  def test_a_light_can_take_a_shape_the_game_gives_it_a_row_at_a_time
    diamond = lit_room { |light| light.shape { |row| 40 - (row - light.y).abs } }
    spans = lit_spans(shown(diamond))

    assert_equal [80, 160], spans[80], "the middle row reaches 40 either side"
    assert_equal [110, 130], spans[110], "thirty rows down reaches 10"
    assert_nil spans[125], "past forty rows nothing is lit"
    assert_backends_agree(diamond, frames: 2, name: "DIAMOND")
  end

  # ...or as the row's two edges, and with the light's own circle to build on. The circle of the
  # row above is how a game that copies its rows in the gap after each line shows its light: each
  # row the span worked out for the row above it, and the top row its own.
  def test_a_shape_can_give_each_row_the_circle_of_the_row_above
    above = lit_room(radius: 82) do |light|
      light.shape do |row|
        half = light.circle((row - 1).clamp(0, HEIGHT - 1))
        [light.x - half, light.x + half]
      end
    end

    assert_same_spans game_circle_spans_a_row_late(120, 80, 82), lit_spans(shown(above)), "a row late"
    assert_backends_agree(above, frames: 2, name: "ABOVE")
  end

  # A shape that reads a number the game changes is worked out again when it changes, on every
  # backend alike.
  def test_a_shape_that_reads_a_changing_number_is_worked_out_again
    widening = lit_room do |light|
      reach = var :reach, 10
      once_a_frame { reach.add! 5 }
      light.shape { |row| reach - (row - light.y).abs }
    end

    assert_backends_agree(widening, frames: [2, 4, 7], name: "WIDEN")
  end

  # A VARIABLE A SHAPE DECLARES STARTS EVERY ROW AS IT WAS DECLARED, so nothing is carried from one
  # row to the next or one frame to the next: a row is the row and the game's numbers, and nothing
  # else, which is what lets the console keep rows it has already worked out.
  def test_a_shapes_own_variable_starts_every_row_afresh
    counting = lit_room do |light|
      light.shape do |row|
        count = var :shape_count, 0
        count.add! 1
        (row - row) + (count * 20)
      end
    end
    spans = lit_spans(shown(counting, frames: 4))

    assert_equal [100, 140], spans[80], "every row reaches 20: the count is 1 on every row"
    assert_backends_agree(counting, frames: [2, 3, 4, 5], name: "OWNVAR")
  end

  # A copy reads a variable as surely as an expression does, so a shape that copies a number the
  # game changes is worked out again when it changes.
  def test_a_shape_that_copies_a_changing_number_is_worked_out_again
    widening = lit_room do |light|
      reach = var :reach, 10
      once_a_frame { reach.add! 5 }
      light.shape do |_row|
        mine = var :shape_reach, 0
        copy! :shape_reach, :reach
        mine + 0
      end
    end

    assert_backends_agree(widening, frames: [2, 4, 7], name: "COPY")
  end
end
