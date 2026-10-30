# frozen_string_literal: true

require "test_helper"
require "differential"

require "stringio"
require VBlank.root.join("examples/dive").to_s

# The places and moments in the Dive example the tests read, kept once for this file and for the
# test of the dive on the Advance's cartridge (test/lowering/gba/examples/test_dive_example_cartridge.rb).
module DiveExampleSpots
  # A title frame or two first, so the button really has an edge to be pressed on. Held
  # from the very first frame it may never go down, and a menu reads the press, not the hold.
  START_AT = 6

  # Somewhere in the diver's suit, measured from the corner its picture starts at.
  SUIT_ACROSS = 8
  SUIT_DOWN = 8

  # A patch of the dive with nothing but rock behind the water, well clear of both the
  # diver and the gauge panel.
  OPEN_WATER = [20, 140].freeze

  # The mask, which is the highest part of the diver, and the middle of the suit.
  MASK_ACROSS = 13
  MASK_DOWN = 2

  # Long enough held UP to run out of sea above and climb out of it.
  SURFACING = 40

  SPECIES = Dive::Fish::SPECIES.length

  private def red_in(color) = color & 0x1F

  private def brightness(color) = (color & 0x1F) + ((color >> 5) & 0x1F) + ((color >> 10) & 0x1F)
end

# The Dive example: a game whose layers and palette are load-bearing. A title screen in
# the console's mixed arrangement (two scrolling layers beside one that turns), a play
# screen in the four-scrolling one, water the diver swims BEHIND, an air gauge that
# empties by changing cells, and a blackout that fades the world while the water goes on
# blending. Each of those is a thing the framework only had tests for; here it is a game.
#
# What only the Advance's cartridge can answer — its display register, its colour table, the
# sprites as it draws them, and running a tank dry — is read back in the emulator in
# test/lowering/gba/examples/test_dive_example_cartridge.rb.
class TestDiveExample < Minitest::Test
  include Differential
  include DiveExampleSpots

  def test_the_example_builds_and_says_nothing
    err = StringIO.new
    rom = Dive.build_rom(out: StringIO.new, err: err)

    assert_operator rom.size, :>, 0, "the game builds one cartridge"
    assert_equal "", err.string, "and the build has no warning to make about it"
  end

  # --- the turning disc ---

  SUN = Dive::Ink::SUN
  SUN_WEDGE = Dive::Ink::SUN_WEDGE

  MIDDLE_X = 120
  MIDDLE_Y = 80
  RING = 12     # well inside the disc at every size it breathes to
  AROUND = 24   # how many points of the ring are sampled

  # Which of the disc's segments — light or dark — is under each point of a ring around
  # the middle of the screen. The disc pivots on that middle, so turning it moves the
  # light and dark segments round this ring and changes nothing else.
  private def segments_round_the_middle(screen)
    (0...AROUND).map do |step|
      angle = step * 2 * Math::PI / AROUND
      screen.pixel(MIDDLE_X + (Math.cos(angle) * RING).round,
                   MIDDLE_Y + (Math.sin(angle) * RING).round) == SUN
    end
  end

  # How far the disc reaches across the middle of the screen, which is what it breathing
  # in and out changes.
  private def disc_width(screen)
    (0...240).count { |x| [SUN, SUN_WEDGE].include?(screen.pixel(x, MIDDLE_Y)) }
  end

  EARLY = 4
  LATE = 34

  private def title_screens
    seen = {}
    i = game_player
    i.each_vblank { |f| seen[f] = [segments_round_the_middle(i.screen), disc_width(i.screen)] }
    i.run(Dive.program, frames: LATE + 1)
    [seen[EARLY], seen[LATE]]
  end

  def test_the_sun_disc_turns_and_swells_on_the_title
    (early_segments, early_width), (late_segments, late_width) = title_screens

    assert_includes early_segments, true, "none of the disc is lit"
    assert_includes early_segments, false, "the disc has no darker segments to turn"
    refute_equal early_segments, late_segments, "the disc did not turn"
    refute_equal early_width, late_width, "the disc did not swell"
  end

  # --- the shafts shimmer ---

  # THE NEAR SHAFTS ADD LIGHT. They show all of what is behind them and three quarters of
  # themselves on top, so where they cross the far sheet the water comes out brighter than
  # any colour the shafts are drawn in — which no layer drawn solid, and no glass that
  # splits one whole between itself and what is behind, can give. Read from the band above
  # the sun, where nothing but the two sheets is drawn, over the title's first half second:
  # the sheets drift, and how bright the band gets depends on where they cross.
  BRIGHTEST_SHAFT = 19 + 26 + 31 # the shimmer's brightest step, the brightest colour a shaft is drawn in

  def test_the_near_shafts_brighten_the_water_behind_them
    brightest = 0
    i = game_player
    i.each_vblank do
      band = (0...40).flat_map { |y| (0...240).map { |x| brightness(i.screen.pixel(x, y)) } }
      brightest = [brightest, band.max].max
    end
    i.run(Dive.program, frames: LATE)

    assert_operator brightest, :>, BRIGHTEST_SHAFT
  end

  # --- handing over to the dive ---

  # A dive starts with the diver's head out of the water, taking a breath, so a test that
  # wants them properly under has to swim them down.
  private def swimming_down_for(frames)
    i = game_player.input_each_frame { |f| f > START_AT ? %i[start down] : [] }
    i.run(Dive.program, frames: frames)
  end

  # --- the water in front of the diver ---

  # Scenery in FRONT of something that moves is the one arrangement a picture cannot fall
  # into by accident, and the water is see-through, so both halves show at once: the diver
  # is visible, and it is visibly UNDER water rather than drawn plain over it.
  def test_the_diver_swims_behind_the_water_and_shows_through_it
    i = swimming_down_for(START_AT + 30)
    drawn = i.sprites(:diver).first
    refute_nil drawn, "the diver is not being drawn at all"

    through = i.screen.pixel(drawn.x + SUIT_ACROSS, drawn.y + SUIT_DOWN)
    refute_equal Dive::Ink::SUIT, through,
                 "the diver is drawn in its own colour — nothing is in front of it"
    assert_operator red_in(through), :>, red_in(i.screen.pixel(*OPEN_WATER)),
                    "the diver does not show through the water at all"
  end

  # --- breaking the surface ---

  private def surfaced
    i = game_player.input_each_frame { |f| f > START_AT ? %i[start up] : [] }
    i.run(Dive.program, frames: START_AT + SURFACING)
  end

  # The water's cells stop at the surface, so above that line there is nothing to see
  # through and what is behind draws plain. Swim up until the head comes out and ONE
  # sprite is half blended and half not — the head in its own colours, the suit below it
  # still under water. Nothing in the game says where that line is; the map says it.
  def test_the_divers_head_comes_out_of_the_water_at_the_top
    i = surfaced
    drawn = i.sprites(:diver).first
    refute_nil drawn, "the diver is not being drawn"

    assert_equal Dive::Ink::MASK, i.screen.pixel(drawn.x + MASK_ACROSS, drawn.y + MASK_DOWN),
                 "the head is still being drawn through water"
    refute_equal Dive::Ink::SUIT, i.screen.pixel(drawn.x + SUIT_ACROSS, drawn.y + SUIT_DOWN),
                 "the whole diver came out — the body should still be under"
  end

  # Bubbles come off a diver who is under water, and stop at the top of the sea. Both are
  # the same line of the game asking where the surface is, which is why neither one needs
  # a picture to prove it: a bubble that is still there is still being drawn.
  def test_no_bubbles_come_off_a_diver_whose_head_is_out
    assert_empty surfaced.sprites(:bubble), "bubbles are still rising from a diver in the air"
  end

  def test_bubbles_rise_from_a_diver_under_water
    refute_empty swimming_down_for(START_AT + 30).sprites(:bubble), "no bubbles come off the diver at all"
  end

  # --- the air gauge ---

  BARS = Dive::Gauge::BARS

  # The middle of one bar of the gauge. The panel is a background that never scrolls, so
  # a cell is where the map put it and a pixel in it is arithmetic.
  private def bar_middle(which)
    [((Dive::Gauge::COL + which) * 8) + 3, (Dive::Gauge::ROW * 8) + 4]
  end

  private def bars_lit(screen)
    (0...BARS).count { |which| screen.pixel(*bar_middle(which)) == Dive::Ink::AIR }
  end

  # These pixels belong to a BACKGROUND, so the only thing that can change one is the
  # cell under it changing — which is the whole point of the gauge being tiles rather
  # than ten of the 128 sprites the console draws at once.
  def test_the_air_gauge_empties_bar_by_bar_as_the_air_goes
    counts = []
    i = game_player.input_each_frame { |f| f > START_AT ? %i[start down] : [] }
    i.each_vblank { |f| counts << bars_lit(i.screen) if f > START_AT + 4 }
    i.run(Dive.program, frames: 150)

    assert_operator counts.first, :>=, BARS - 1, "the tank does not start full"
    assert_equal counts, counts.sort.reverse, "the gauge refilled while the air was going"
    assert_operator counts.last, :<, counts.first, "the gauge never lost a bar"
  end

  # --- the fish ---

  # Somewhere in a fish's body, measured from the corner its picture starts at.
  FLANK_ACROSS = 8
  FLANK_DOWN = 3

  # One picture, drawn in a different list of colours per fish. The shape and the shading
  # stay exactly as drawn and only the colours move, which is why a shoal of six costs one
  # picture rather than six.
  def test_the_fish_wear_their_own_colours
    i = swimming_down_for(START_AT + 30)
    seen = i.sprites(:fish).filter_map { |f| i.screen.pixel(f.x + FLANK_ACROSS, f.y + FLANK_DOWN) }

    assert_operator seen.length, :>=, SPECIES, "not every fish is being drawn"
    assert_operator seen.uniq.length, :>=, SPECIES, "the fish are all drawn in the same colours"
  end

  # --- every pixel, both backends ---
  #
  # The assertions above are pixels somebody thought to look at. This is the other 38,398:
  # a layer numbered differently by the two, a blend that reached the wrong one, or a
  # turning layer a degree out shows up here and nowhere else.

  # The title only. The dive is past a START press, and a whole-screen comparison can hold
  # a button but cannot tap one — a held button gives the oracle no press edge to see by
  # design, so the two backends would be on different screens. The dive's own picture is
  # covered above instead, each of those assertions made on both backends.
  def test_the_two_backends_draw_the_same_title
    assert_backends_agree(Dive.program, frames: 4)
  end
end
