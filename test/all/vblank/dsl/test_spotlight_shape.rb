# frozen_string_literal: true

require "test_helper"

# `light.shape { |row| ... }` and `light.circle(row)`: a light given a shape of the game's own, a
# row of the screen at a time. What is asserted is the picture — each row's lit span — and that
# every backend draws the same one, frame after frame: the rows are worked out in the gap before a
# frame, and the console skips them on a frame where nothing they read has changed, so a shape
# that could change anything or carry anything from one row to the next would show differently
# there. Those shapes are refused, and the refusals are asserted too.
class TestSpotlightShape < Minitest::Test
  WHITE = Color.resolve(:white)

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

  def test_a_shape_variable_the_game_also_uses_is_refused
    error = assert_raises(ArgumentError) do
      program do
        screen :tiled
        light = spotlight at: [120, 80], radius: 40, dark: 100
        light.shape do |_row|
          w = var :width, 20
          w + 0
        end
        game_loop { add! :width, 1 }
      end
    end

    assert_match(/the rest of the game uses it too/, error.message)
  end

  def test_a_shape_that_changes_a_game_variable_is_refused
    error = assert_raises(ArgumentError) do
      lit_room do |light|
        seen = var :seen, 0
        light.shape { |_row| seen.add!(1); 20 }
      end
    end

    assert_match(/changes the variable :seen/, error.message)
  end

  def test_a_shape_that_copies_into_a_game_variable_is_refused
    error = assert_raises(ArgumentError) do
      lit_room do |light|
        var :kept, 0
        light.shape { |_row| copy! :kept, :__spotlight_x; 20 }
      end
    end

    assert_match(/changes the variable :kept/, error.message)
  end

  # A random number moves the stream every other part of the game draws from too.
  def test_a_shape_that_picks_a_random_number_is_refused
    error = assert_raises(ArgumentError) { lit_room { |light| light.shape { |_row| rand(10..20) } } }

    assert_match(/the whole game shares/, error.message)
  end

  def test_a_shape_that_reads_a_list_is_refused
    error = assert_raises(ArgumentError) do
      lit_room do |light|
        widths = list :widths, capacity: 4, full_of: 10
        light.shape { |row| widths[row & 3] }
      end
    end

    assert_match(/list/, error.message)
  end

  def test_a_shape_that_stops_the_game_or_a_timer_is_refused
    stops = [-> { halt }, lambda {
      t = timer :tick, per_second: 60
      t.stop
    }]
    stops.each do |stop|
      error = assert_raises(ArgumentError) { lit_room { |light| light.shape { |_row| instance_exec(&stop); 20 } } }

      assert_match(/A shape can only work numbers out/, error.message)
    end
  end

  def test_a_light_has_one_shape
    error = assert_raises(ArgumentError) do
      lit_room do |light|
        light.shape { 10 }
        light.shape { 20 }
      end
    end

    assert_match(/shape twice/, error.message)
  end

  def test_a_shape_gives_back_a_width_or_two_edges
    [[1, 2, 3], [:left, nil], :wide].each do |gave|
      error = assert_raises(ArgumentError) { lit_room { |light| light.shape { gave } } }

      assert_match(/half width/, error.message, gave.inspect)
    end
  end

  def test_a_circle_outside_a_shape_is_refused
    error = assert_raises(ArgumentError) { lit_room { |light| light.circle(0) } }

    assert_match(/inside `light.shape/, error.message)
  end
end
