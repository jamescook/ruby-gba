# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test_hardware_sprite_scale.rb whose games draw a sprite bigger or smaller than it
# was drawn, which a Game Boy Color's hardware cannot do, so they play on the Advance's runs alone.
class TestHardwareSpriteScaleOnTheAdvance < Minitest::Test
  include Differential

  # A solid 16x16 red square. Solid on purpose: how many pixels it covers IS its drawn
  # size, with no transparent gaps to make the count depend on the shape.
  BLOCK = (["#" * 16] * 16).join("\n")
  SIDE = 16

  # Placed well clear of every screen edge, so nothing is clipped at any size it is
  # tested at and the coverage count means what it says.
  AT = [100, 60].freeze

  private def sized_program(size = nil, angle: nil, frames: 2)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :blue) { (["########"] * 8).join("\n") }
      image(:block, "#" => :red) { BLOCK }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: Array.new(20, "#" * 30)
      block = sprite :block, at: AT
      block.scale(size) if size
      block.face_angle(angle) if angle
      f = var :f, 0
      game_loop do
        wait_vblank
        f.add! 1
        (f >= frames).then { halt }
      end
    end
    builder.finalize_program
    builder.program
  end

  # How many pixels of the screen the sprite covers — everything in a generous box
  # around it that isn't the blue floor.
  private def covered(program)
    screen = game_player.run(program).screen
    floor = Color.resolve(:blue)
    box = (-40..80)
    box.sum { |dy| box.count { |dx| screen.pixel(AT[0] + dx, AT[1] + dy) != floor } }
  end

  # --- it changes size, and by the amount asked for ---

  # Left alone, the sprite covers exactly its own 16x16.
  def test_at_its_own_size_it_covers_its_own_area
    assert_equal SIDE * SIDE, covered(sized_program(1.0))
  end

  # Twice the size is twice as wide AND twice as tall — four times the area.
  def test_at_twice_the_size_it_covers_four_times_the_area
    assert_equal (SIDE * 2) * (SIDE * 2), covered(sized_program(2.0))
  end

  # Half the size is a quarter of the area, the same rule the other way.
  def test_at_half_the_size_it_covers_a_quarter_of_the_area
    assert_equal (SIDE / 2) * (SIDE / 2), covered(sized_program(0.5))
  end

  # A size with a fraction is honored rather than rounded to a whole number of times:
  # 1.5 lands between its neighbours, not on one of them.
  def test_a_size_with_a_fraction_lands_between_the_whole_ones
    at_one_and_a_half = covered(sized_program(1.5))
    assert_operator at_one_and_a_half, :>, covered(sized_program(1.0))
    assert_operator at_one_and_a_half, :<, covered(sized_program(2.0))
  end

  # --- the size is a number the game can work out ---

  # `scale` with no argument hands back the size, so it eases like anything else. Growing
  # by a tenth for ten frames arrives near twice the size.
  def test_the_size_can_be_eased_frame_by_frame
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :blue) { (["########"] * 8).join("\n") }
      image(:block, "#" => :red) { BLOCK }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: Array.new(20, "#" * 30)
      block = sprite :block, at: AT
      f = var :f, 0
      game_loop do
        wait_vblank
        block.scale.approach! 2.0, 0.1
        f.add! 1
        (f >= 12).then { halt }
      end
    end
    builder.finalize_program
    interpreter = game_player.run(builder.program)
    # Ten steps of a tenth from 1.0 reaches 2.0 and `approach` holds it there.
    assert_in_delta 2.0, interpreter[:__obj1_scale] / 65_536.0, 0.01
  end

  # --- the console draws what the oracle says it draws ---

  # Every pixel on the screen, at a size the console has to work out a reciprocal for.
  def test_the_console_draws_a_resized_sprite_the_same_way
    assert_backends_agree(sized_program(1.5, frames: 3), frames: 3)
  end

  # ...and smaller than drawn, where the reciprocal is the other side of 1.
  def test_the_console_draws_a_shrunk_sprite_the_same_way
    assert_backends_agree(sized_program(0.5, frames: 3), frames: 3)
  end

  # Size and angle ride in the same four numbers, so a sprite doing both has to be right
  # in both at once — this is the case a separate rotation path would get wrong.
  def test_the_console_draws_a_sprite_that_turns_and_resizes_at_once
    assert_backends_agree(sized_program(1.5, angle: 45, frames: 3), frames: 3)
  end
end
