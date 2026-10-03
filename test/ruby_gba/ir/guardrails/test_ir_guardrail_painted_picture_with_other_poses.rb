# frozen_string_literal: true

require "test_helper"

require "stringio"

# A picture the game paints from a list (`image :tag, from: list`) is the whole of the sprite
# that shows it. Mixed in among ordinary pictures as one pose of several, it has no place in
# sprite memory on the console, so the build refuses it rather than stopping with no word of why.
class TestIRGuardrailPaintedPictureWithOtherPoses < Minitest::Test
  Check = RubyGBA::IR::Guardrails::Checks::PaintedPictureWithOtherPoses

  def program(&block)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :ink, [:transparent, :white]
      canvas = list :canvas, capacity: 64, width: :byte
      image :tag, from: canvas, width: 16, height: 8, colors: :ink
      image(:plain, "#" => :white, colors: :ink) { (["#" * 16] * 8).join("\n") }
      instance_eval(&block)
      game_loop { nil }
    end
    b.finalize_program
    b.program
  end

  def test_a_painted_picture_beside_an_ordinary_pose_is_refused
    findings = Check.new.detect(program { sprite :speaker, at: [0, 0], facing: { left: :plain, right: :tag } })

    assert_equal 1, findings.length
    assert_equal :error, findings.first.severity
    assert_match(/:speaker/, findings.first.message)
    assert_match(/:tag/, findings.first.message)
  end

  def test_a_sprite_showing_only_its_painted_picture_or_only_ordinary_ones_is_left_alone
    findings = Check.new.detect(program do
      sprite :tag, at: [0, 0]
      sprite :plain, at: [20, 0]
    end)

    assert_empty findings
  end

  def test_the_build_stops_and_explains
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("MIXED", out: StringIO.new, err: err) do
        screen :tiled
        colors :ink, [:transparent, :white]
        canvas = list :canvas, capacity: 64, width: :byte
        image :tag, from: canvas, width: 16, height: 8, colors: :ink
        image(:plain, "#" => :white, colors: :ink) { (["#" * 16] * 8).join("\n") }
        sprite :speaker, at: [0, 0], facing: { left: :plain, right: :tag }
        game_loop { nil }
      end
    end

    assert_match(/:speaker/, err.string)
  end
end
