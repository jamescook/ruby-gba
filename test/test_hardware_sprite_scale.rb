# frozen_string_literal: true

require "test_helper"
require "differential"

# Drawing a hardware sprite bigger or smaller than it was drawn. On a `screen :tiled`,
# `sprite.scale(1.5)` resizes the picture about its own center — the same display
# hardware `face_angle` turns it with, so the two compose. These assert the observable
# result: how much of the screen the sprite ends up covering, that the size can be eased
# like any other number, that the console and the oracle draw the identical picture, and
# the friendly guardrails. The dev never touches a matrix, a reciprocal, or a division.
class TestHardwareSpriteScale < Minitest::Test
  include Differential

  # A solid 16x16 red square. Solid on purpose: how many pixels it covers IS its drawn
  # size, with no transparent gaps to make the count depend on the shape.
  BLOCK = (["#" * 16] * 16).join("\n")
  SIDE = 16

  # Placed well clear of every screen edge, so nothing is clipped at any size it is
  # tested at and the coverage count means what it says.
  AT = [100, 60].freeze

  def sized_program(size = nil, angle: nil, frames: 2)
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
        f.add 1
        (f >= frames).then { halt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  # How many pixels of the screen the sprite covers — everything in a generous box
  # around it that isn't the blue floor.
  def covered(program)
    screen = Reference.new.run(program).screen
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
        block.scale.approach 2.0, 0.1
        f.add 1
        (f >= 12).then { halt }
      end
    end
    builder.emit_pending_functions
    interpreter = Reference.new.run(builder.program)
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

  # --- friendly guardrails ---

  # A size of zero has no reciprocal and would draw nothing — a friendly error where it
  # is written, naming what to use instead.
  def test_a_size_of_zero_is_a_friendly_error
    err = assert_raises(ArgumentError) { scale_a_tiled_sprite_to(0) }
    assert_match(/more than 0/, err.message)
    assert_match(/hide/, err.message)
  end

  def test_a_negative_size_is_a_friendly_error
    err = assert_raises(ArgumentError) { scale_a_tiled_sprite_to(-1.0) }
    assert_match(/more than 0/, err.message)
  end

  # A bitmap sprite is copied to the screen pixel for pixel, so there is no step where a
  # different size could come out. A friendly error that points at the screen mode.
  def test_a_bitmap_sprite_cannot_change_size
    builder = Builder.new
    err = assert_raises(ArgumentError) do
      builder.instance_eval do
        screen :bitmap
        image(:hero, "#" => :red) { (["########"] * 8).join("\n") }
        clear_screen :black
        sprite(:hero, at: [10, 10]).scale(2.0)
      end
    end
    assert_match(/screen :tiled/, err.message)
  end

  def scale_a_tiled_sprite_to(size)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :blue) { (["########"] * 8).join("\n") }
      image(:block, "#" => :red) { BLOCK }
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: Array.new(20, "#" * 30)
      sprite(:block, at: AT).scale(size)
    end
  end

  # --- what it costs ---

  # A sprite that resizes is dearer to draw than one that only turns, which is dearer
  # than one that only moves — because each does strictly more work, ending in a division
  # the author never wrote. An estimate that priced them the same would let a screenful
  # of resizing sprites read as free.
  # The three programs differ in exactly one thing — what the sprite does — so the
  # comparison is of the transform and nothing else.
  def test_resizing_costs_more_than_turning_costs_more_than_moving
    model = RubyGBA::IR::CostModel.new
    moving = model.steady_cost(sized_program)
    turning = model.steady_cost(sized_program(angle: 45))
    resizing = model.steady_cost(sized_program(1.5, angle: 45))

    assert_operator turning, :>, moving, "turning costs more than moving"
    assert_operator resizing, :>, turning, "resizing costs more than turning"
  end

  # The estimate says which sprites do the expensive thing, not just how many there are —
  # otherwise one line of the report hides a threefold difference in what it stands for.
  def test_the_report_names_the_sprites_that_resize
    labels = tree_labels(RubyGBA::IR::CostModel.new.analyze(sized_program(1.5)))
    assert labels.any? { |label| label.include?("resizing") },
           "expected a sprite line naming the resize, got: #{labels.inspect}"
  end

  def tree_labels(nodes)
    nodes.flat_map { |node| [node[:label].to_s] + tree_labels(node[:children].to_a) }
  end

  # --- the two backends build the matrix from one set of rules ---

  # The DSL's fraction scale and the IR's "as drawn" size are the same number by
  # construction — that is what lets `scale(1.5)` reach the object node with nothing to
  # convert. If either moves without the other, every size is silently wrong by a factor.
  def test_the_drawn_size_matches_the_dsl_fraction_scale
    assert_equal RubyGBA::IR::Build::SCALE_ONE,
                 RubyGBA::Fraction.scale(1.0, RubyGBA::Fraction::DEFAULT_BITS)
  end

  # A size of zero can still arrive at run time (the build-time error only catches one
  # written down), so the shared matrix rules hold it at the smallest size rather than
  # dividing by zero — which the two backends would answer differently.
  def test_a_size_of_zero_at_run_time_is_held_rather_than_divided_by
    affine = RubyGBA::IR::Affine
    assert_equal affine.reciprocal(affine::MIN_SCALE), affine.reciprocal(0)
    assert_equal affine.reciprocal(affine::MIN_SCALE), affine.reciprocal(-100)
  end

  # At its own size the matrix is the plain rotation it always was — so adding size
  # changed nothing for a sprite that only turns.
  def test_at_its_own_size_the_matrix_is_the_plain_rotation
    affine = RubyGBA::IR::Affine
    assert_equal [affine.sine(90), affine.sine(0), -affine.sine(0), affine.sine(90)],
                 affine.matrix(0, RubyGBA::IR::Build::SCALE_ONE)
  end
end
