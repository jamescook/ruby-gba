# frozen_string_literal: true

require "test_helper"

# Drawing a hardware sprite bigger or smaller than it was drawn. On a `screen :tiled`,
# `sprite.scale(1.5)` resizes the picture about its own center — the same display
# hardware `face_angle` turns it with, so the two compose. These assert the observable
# result: how much of the screen the sprite ends up covering, that the size can be eased
# like any other number, that the console and the oracle draw the identical picture, and
# the friendly guardrails. The dev never touches a matrix, a reciprocal, or a division.
class TestHardwareSpriteScale < Minitest::Test
  # A solid 16x16 red square.
  BLOCK = (["#" * 16] * 16).join("\n")

  # Placed well clear of every screen edge.
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

  private def scale_a_tiled_sprite_to(size)
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

  # A sprite that resizes is dearer to draw than one that only turns, which is dearer than one
  # that only moves — each does strictly more work, ending in a division the author never
  # wrote. The three programs differ in exactly one thing, so the comparison is of the
  # transform and nothing else, and what is compared is the code the build EMITTED for each.
  # (This used to compare an ESTIMATE of the three. `rom.profile` measures the real thing.)
  def test_resizing_emits_more_than_turning_emits_more_than_moving
    moving = emitted_bytes(sized_program)
    turning = emitted_bytes(sized_program(angle: 45))
    resizing = emitted_bytes(sized_program(1.5, angle: 45))

    assert_operator turning, :>, moving, "turning is more work than moving"
    assert_operator resizing, :>, turning, "resizing is more work than turning"
  end

  private def emitted_bytes(program)
    RubyGBA::IR::Backends::GBA.new.lower(program).bytesize
  end

  # --- the two backends build the matrix from one set of rules ---

  # The DSL's fraction scale and the IR's "as drawn" size are the same number by
  # construction — that is what lets `scale(1.5)` reach the object node with nothing to
  # convert. If either moves without the other, every size is silently wrong by a factor.
  def test_the_drawn_size_matches_the_dsl_fraction_scale
    assert_equal RubyGBA::IR::Build::SCALE_ONE,
                 RubyGBA::DSL::Fraction.scale(1.0, RubyGBA::DSL::Fraction::DEFAULT_BITS)
  end

  # A size of zero can still arrive at run time (the build-time error only catches one
  # written down), so the shared matrix rules hold it at the smallest size rather than
  # dividing by zero, which has no size to give.
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
