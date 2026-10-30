# frozen_string_literal: true

require "test_helper"
require "console/gba/examples/test_dive_example"

# The Dive example (examples/dive.rb) on the Advance's cartridge, read back in the emulator: the
# console's display register, its colour table, the sprites as it draws them, and a tank run dry.
# What the game does on every run is in test/console/gba/examples/test_dive_example.rb.
class TestDiveExampleCartridge < Minitest::Test
  include VBlank::Console::Hardware # REG_DISPCNT
  include DiveExampleSpots

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

  private def holding_start = ->(frame) { frame > START_AT ? KEY_START : 0 }

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

  # The other arrangement, in the same cartridge: four layers that scroll and nothing
  # turning. Nothing in the game asks for either one — the title turns a background and
  # this screen does not, and the build reads the arrangement off that.
  def test_starting_hands_the_console_over_to_four_scrolling_layers
    reg = console(frames: START_AT + 8, keys: holding_start).mem16(REG_DISPCNT)

    assert_equal SCROLLING_ONLY, reg & ARRANGEMENT, "the dive is not the four-scrolling arrangement"
    assert_equal [0, 1, 2, 3], layers_on(reg), "the dive did not get all four layers"
  end

  # --- breaking the surface ---

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

  # ...and the console agrees, which is the half no oracle can answer: on the console the
  # colours come from which group of colours the fish's table entry names, so this reads
  # the entries rather than the pixels.
  def test_the_console_gives_each_fish_its_own_colours
    worn = console(frames: START_AT + 10, keys: holding_start).sprites(:fish).map(&:colors)

    assert_operator worn.length, :>=, SPECIES, "not every fish reached the console"
    assert_operator worn.uniq.length, :>=, SPECIES, "the console drew the fish all one colour"
  end
end
