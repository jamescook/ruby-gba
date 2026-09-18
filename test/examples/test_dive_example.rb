# frozen_string_literal: true

require "test_helper"
require "differential"

require "stringio"
require_relative "../../examples/dive"

# The Dive example: a game whose layers and palette are load-bearing. A title screen in
# the console's mixed arrangement (two scrolling layers beside one that turns), a play
# screen in the four-scrolling one, water the diver swims BEHIND, an air gauge that
# empties by changing cells, and a blackout that fades the world while the water goes on
# blending. Each of those is a thing the framework only had tests for; here it is a game.
class TestDiveExample < Minitest::Test
  include Differential
  include RubyGBA::Cartridge::Constants # REG_DISPCNT

  # Which of the console's arrangements is in force sits in the low three bits of its
  # display register, and which background layers are switched on in the byte above.
  ARRANGEMENT = 0x7
  SCROLLING_ONLY = 0
  ONE_TURNS = 1

  private def layers_on(value) = (0..3).select { |bg| value.anybits?(1 << (8 + bg)) }

  private def console(frames:, keys: 0)
    rom = Dive.build_rom(out: StringIO.new, err: StringIO.new)
    assert_emulator_loads_rom(rom, frames: frames, keys: keys, vars: rom.var_addresses)
  end

  def test_the_example_builds_and_says_nothing
    err = StringIO.new
    rom = Dive.build_rom(out: StringIO.new, err: err)

    assert_operator rom.size, :>, 0, "the game builds one cartridge"
    assert_equal "", err.string, "and the build has no warning to make about it"
  end

  # The title is the console's MIXED arrangement: two layers that scroll beside one that
  # turns. Read off the console's own display register rather than guessed from the
  # picture, because the half a picture hides is the fourth layer being switched OFF —
  # that arrangement has no fourth layer, and a bit left on there means nothing to the
  # hardware and everything to the next scene.
  def test_the_title_puts_the_console_in_the_arrangement_that_holds_a_turning_layer
    reg = console(frames: 4).mem16(REG_DISPCNT)

    assert_equal ONE_TURNS, reg & ARRANGEMENT, "the title is not the turning arrangement"
    assert_equal [0, 1, 2], layers_on(reg), "the title's three layers are not the ones switched on"
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
    i = Reference.new
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

  # The near sheet of light shafts is drawn from the next of four lists of colours every
  # eight frames, which is light moving on water. What makes it worth a test rather than a
  # look is the second half of the promise: the colours that move are that layer's ALONE.
  # Both sheets of shafts are drawn from the same tiles, so if the two shared one group of
  # sixteen the far sheet would flicker in step with the near one, and nothing in the game
  # would say why.
  #
  # Read off the console's own colour table rather than off the picture, because both sheets
  # are also drifting: a pixel that changed could be the shimmer or could be a shaft that
  # slid one across, and the table cannot be confused that way.
  HELD_FOR = 8 # frames a step of the shimmer is held

  def test_the_near_shafts_shimmer_and_no_other_colour_moves
    v = console(frames: 4)
    tables = Array.new(4) { v.palette.first(256).tap { v.step(HELD_FOR) } }
    moved = (0...256).select { |slot| tables.map { |table| table[slot] }.uniq.length > 1 }

    refute_empty moved, "no colour moved at all: the shafts are not shimmering"
    assert_operator moved.length, :<=, 2, "more moved than the shafts' own two colours: #{moved.inspect}"
    assert_equal 1, moved.map { |slot| slot / 16 }.uniq.length,
                 "the colours that moved are spread over more than one layer's own group: #{moved.inspect}"
  end

  # --- handing over to the dive ---

  # A title frame or two first, so the button really has an edge to be pressed on. Held
  # from the very first frame it may never go down, and a menu reads the press, not the hold.
  START_AT = 6

  private def holding_start = ->(frame) { frame > START_AT ? KEY_START : 0 }

  private def dive_after(frames)
    i = Reference.new.input_each_frame { |f| f > START_AT ? [:start] : [] }
    i.run(Dive.program, frames: frames)
  end

  # A dive starts with the diver's head out of the water, taking a breath, so a test that
  # wants them properly under has to swim them down.
  private def swimming_down_for(frames)
    i = Reference.new.input_each_frame { |f| f > START_AT ? %i[start down] : [] }
    i.run(Dive.program, frames: frames)
  end

  # The other arrangement, in the same cartridge: four layers that scroll and nothing
  # turning. Nothing in the game asks for either one — the title turns a background and
  # this screen does not, and the build reads the arrangement off that.
  def test_starting_hands_the_console_over_to_four_scrolling_layers
    reg = console(frames: START_AT + 8, keys: holding_start).mem16(REG_DISPCNT)

    assert_equal SCROLLING_ONLY, reg & ARRANGEMENT, "the dive is not the four-scrolling arrangement"
    assert_equal [0, 1, 2, 3], layers_on(reg), "the dive did not get all four layers"
  end

  # --- the water in front of the diver ---

  # Somewhere in the diver's suit, measured from the corner its picture starts at.
  SUIT_ACROSS = 8
  SUIT_DOWN = 8

  # A patch of the dive with nothing but rock behind the water, well clear of both the
  # diver and the gauge panel.
  OPEN_WATER = [20, 140].freeze

  private def red_in(color) = color & 0x1F

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

  # The mask, which is the highest part of the diver, and the middle of the suit.
  MASK_ACROSS = 13
  MASK_DOWN = 2

  # Long enough held UP to run out of sea above and climb out of it.
  SURFACING = 40

  private def surfaced
    i = Reference.new.input_each_frame { |f| f > START_AT ? %i[start up] : [] }
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

  # ...and the console draws the same half-and-half diver, which is the half no oracle can
  # settle: the line is where a background layer's empty cells begin, and only the display
  # knows that as it draws each row.
  def test_the_console_draws_the_same_half_submerged_diver
    v = console(frames: START_AT + SURFACING + 2, keys: ->(frame) { frame > START_AT ? KEY_START | KEY_UP : 0 })
    drawn = v.sprites(:diver).first
    refute_nil drawn, "the diver is not being drawn on the console"

    assert_equal Dive::Ink::MASK, v.pixel_gba(drawn.x + MASK_ACROSS, drawn.y + MASK_DOWN),
                 "the console draws the head through water"
    refute_equal Dive::Ink::SUIT, v.pixel_gba(drawn.x + SUIT_ACROSS, drawn.y + SUIT_DOWN),
                 "the console brought the whole diver out"
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
    i = Reference.new.input_each_frame { |f| f > START_AT ? %i[start down] : [] }
    i.each_vblank { |f| counts << bars_lit(i.screen) if f > START_AT + 4 }
    i.run(Dive.program, frames: 150)

    assert_operator counts.first, :>=, BARS - 1, "the tank does not start full"
    assert_equal counts, counts.sort.reverse, "the gauge refilled while the air was going"
    assert_operator counts.last, :<, counts.first, "the gauge never lost a bar"
  end

  # --- running out of air ---
  #
  # These run on the console rather than on the headless oracle, for two reasons. Running
  # a tank dry takes hundreds of frames and the oracle mixes five layers of picture in
  # Ruby on every one of them. And the mixing is the thing under test here, so the console
  # is where the answer counts.

  BLACKOUT_BY = 600 # frames: comfortably past running the tank dry on the way down
  PART_WAY = 8      # frames into the fade — dark, and nowhere near arrived

  # Dive until the air is gone and the world starts going dark.
  private def at_the_blackout
    v = console(frames: START_AT + 4, keys: holding_start)
    BLACKOUT_BY.times do
      v.step(1, keys: KEY_DOWN)
      break if v.var(:blacking_out) == 1
    end
    assert_equal 1, v.var(:blacking_out), "the tank never ran dry on the way down"
    v
  end

  # Where the diver is, and a patch of open water, as the console really drew them.
  private def suit_and_water(verifier)
    drawn = verifier.sprites(:diver).first
    refute_nil drawn, "the diver has stopped being drawn"
    [verifier.pixel_gba(drawn.x + SUIT_ACROSS, drawn.y + SUIT_DOWN),
     verifier.pixel_gba(*OPEN_WATER)]
  end

  private def brightness(color) = (color & 0x1F) + ((color >> 5) & 0x1F) + ((color >> 10) & 0x1F)

  # THE ONE THAT MATTERS. Seeing through a layer and darkening a finished picture are the
  # same part of the display, and it does one at a time — so a game that does both has to
  # move the COLOURS instead, and that is what keeps the water blending here. Get it wrong
  # and the water turns solid the instant the fade starts: the diver disappears behind a
  # flat sheet and pops back when the fade lifts.
  def test_the_water_goes_on_blending_while_the_world_fades_out
    v = at_the_blackout
    lit_suit, lit_water = suit_and_water(v)
    v.step(PART_WAY, keys: KEY_DOWN)
    dim_suit, dim_water = suit_and_water(v)

    assert_operator brightness(dim_water), :<, brightness(lit_water), "the world is not going dark"
    assert_operator red_in(lit_suit), :>, red_in(lit_water), "the diver was hidden before the fade"
    assert_operator red_in(dim_suit), :>, red_in(dim_water),
                    "the water went solid as the fade started and hid the diver behind it"
  end

  # ...and the dive ends: once the screen has actually arrived at black, the game hands
  # over to its own screen, and START starts again with a full tank.
  def test_running_out_of_air_ends_the_dive_and_start_begins_another
    v = at_the_blackout
    BLACKOUT_BY.times do
      v.step(1, keys: KEY_DOWN)
      break if v.var(:state) == Dive::OVER
    end
    assert_equal Dive::OVER, v.var(:state), "the world went dark and the dive never ended"

    v.step(1, keys: KEY_START)
    v.step(4)

    assert_equal Dive::PLAY, v.var(:state), "START did not start another dive"
    assert_equal Dive::Gauge::FULL, v.var(:air), "the new dive did not start with a full tank"
  end

  # --- the fish ---

  # Somewhere in a fish's body, measured from the corner its picture starts at.
  FLANK_ACROSS = 8
  FLANK_DOWN = 3

  SPECIES = Dive::Fish::SPECIES.length

  # One picture, drawn in a different list of colours per fish. The shape and the shading
  # stay exactly as drawn and only the colours move, which is why a shoal of six costs one
  # picture rather than six.
  def test_the_fish_wear_their_own_colours
    i = swimming_down_for(START_AT + 30)
    seen = i.sprites(:fish).filter_map { |f| i.screen.pixel(f.x + FLANK_ACROSS, f.y + FLANK_DOWN) }

    assert_operator seen.length, :>=, SPECIES, "not every fish is being drawn"
    assert_operator seen.uniq.length, :>=, SPECIES, "the fish are all drawn in the same colours"
  end

  # ...and the console agrees, which is the half no oracle can answer: on the console the
  # colours come from which group of colours the fish's table entry names, so this reads
  # the entries rather than the pixels.
  def test_the_console_gives_each_fish_its_own_colours
    worn = console(frames: START_AT + 10, keys: holding_start).sprites(:fish).map(&:colors)

    assert_operator worn.length, :>=, SPECIES, "not every fish reached the console"
    assert_operator worn.uniq.length, :>=, SPECIES, "the console drew the fish all one colour"
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
