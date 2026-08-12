# frozen_string_literal: true

require "test_helper"
require "differential"

require_relative "../examples/lake"

# The lake example: a scene, water that bends row by row over it, and jellyfish drifting
# across half see-through.
#
# The claim worth testing is the one an author cannot check by reading the code — that
# what shows inside a jellyfish IS the lake, mixed in rather than copied. A flat colour
# painted a bit paler would look almost the same in a screenshot and be a different thing
# entirely, so these assert it the only way that tells them apart: the bell is one flat
# colour in the art, and on screen it comes out as several, each one that colour mixed
# with whatever the water happens to be doing underneath.
class TestLakeExample < Minitest::Test
  include Differential

  # The art, as the example draws it.
  BELL = RubyGBA::Color.rgb(31, 26, 31)
  WATER = RubyGBA::Color.rgb(6, 11, 24)
  GLINT = RubyGBA::Color.rgb(28, 27, 17) # the sun's reflection, the brightest thing in the lake

  # How far the blend goes, in the sixteenths the display counts in.
  STEPS = (Lake::SEE_THROUGH * 16) / 100

  # One colour mixed over another, the way the display does it: each channel takes its
  # share of each side, the two are added, and the sixteenth is dropped once.
  def self.blend(top, bottom)
    keep = 16 - STEPS
    (0..2).sum do |channel|
      shift = channel * 5
      a = (top >> shift) & 0x1F
      b = (bottom >> shift) & 0x1F
      (((a * keep) + (b * STEPS)) / 16) << shift
    end
  end

  BELL_OVER_WATER = blend(BELL, WATER)
  BELL_OVER_GLINT = blend(BELL, GLINT)

  def screen_at(frames)
    Reference.new.run(Lake.program, frames: frames).screen
  end

  def colors_on(screen)
    (0...160).flat_map { |y| (0...240).map { |x| screen.pixel(x, y) } }.uniq
  end

  # --- the jellyfish are see-through ---

  # Nowhere on screen is the bell its own colour. Every pixel of it has the lake mixed in,
  # which is what "see-through" means and what a paler sprite would fail.
  def test_no_pixel_of_a_jellyfish_is_the_colour_it_was_drawn
    refute_includes colors_on(screen_at(8)), BELL
  end

  def test_a_bell_shows_the_water_behind_it
    assert_includes colors_on(screen_at(8)), BELL_OVER_WATER
  end

  # THE ONE THAT SAYS IT IS REALLY THE LAKE. The bell is a single flat colour, so two
  # different colours inside it can only come from two different things behind it — here
  # the open water and the sun's bright reflection, as a jellyfish drifts across the
  # pillar. A sprite drawn paler could never do this.
  def test_one_flat_bell_shows_two_different_things_behind_it
    seen = colors_on(screen_at(JELLY_OVER_THE_SUN))

    assert_includes seen, BELL_OVER_WATER
    assert_includes seen, BELL_OVER_GLINT
  end

  # The frame a jellyfish is crossing the sun's reflection. Measured, and it moves if the
  # drift speeds or start positions change — which is worth being told about.
  JELLY_OVER_THE_SUN = 32

  # --- and the water still bends ---

  # The whole point of the example before the jellyfish arrived. A jellyfish layer in
  # front must not have cost it: the wave still travels, so the same row of the lake shows
  # something different a few frames later.
  def test_the_ripple_still_travels
    row = ->(screen) { (0...240).map { |x| screen.pixel(x, 120) } }

    refute_equal row.call(screen_at(8)), row.call(screen_at(24)), "the wave is not moving any more"
  end

  # --- and the console draws the same lake ---

  # Asked as "which colours are on the lake" rather than "what is at this pixel", because
  # the jellyfish drift a pixel or two every frame and the two backends do not start
  # counting frames at the same moment. The claim does not need a coordinate: a bell that
  # was not blending would put its own flat colour on screen and no blend anywhere.
  #
  # The water is drawn in three shades, so a bell can be over any of them — hence a set to
  # look for rather than one number. And the emulator blends in eight bits where the
  # console blends in five, so it may read a step high on a channel; the exact arithmetic
  # is what the interpreter assertions above pin, and this asks only that the blend
  # happened at all (see Differential::EMULATOR_BLEND_SLACK).
  BELL_OVER_ANY_WATER = [WATER, RubyGBA::Color.rgb(8, 14, 27), RubyGBA::Color.rgb(10, 17, 29)]
                        .map { |shade| blend(BELL, shade) }.freeze

  def test_the_console_blends_the_jellyfish_into_the_lake
    seen = RubyGBA::Verifier.new(assemble_rom(Lake.program, name: "LAKE"), frames: 9).frame_gba.uniq
    blended = seen.any? do |shown|
      BELL_OVER_ANY_WATER.any? { |want| within_slack?(want, shown, EMULATOR_BLEND_SLACK) }
    end

    assert blended, "the console draws a bell with the water mixed in"
    refute_includes seen, BELL, "and no pixel of a bell is its own colour"
  end

  # The background half of the picture, every pixel of it. The bend and the scene agree
  # exactly; the jellyfish are left out because the two backends present a moving sprite
  # a frame apart from each other (see the note in the bands below).
  ABOVE_THE_SWIMMERS = 90

  def test_the_two_backends_draw_the_same_lake_above_the_swimmers
    oracle, console = backend_pictures(Lake.program, frames: 8, name: "LAKE")
    bad = mismatched_pixels(oracle, console).reject { |_x, y, _want, _got| y >= ABOVE_THE_SWIMMERS }

    assert_empty bad, "the scene and the rippling water disagree"
  end
end
