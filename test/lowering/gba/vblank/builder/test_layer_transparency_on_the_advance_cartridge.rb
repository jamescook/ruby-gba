# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_layer_transparency"

# The see-through pictures only the Advance plays, read back from its cartridge in the emulator
# and held to what the interpreter draws. The same games on every run that plays the Advance are
# in test/console/gba/vblank/builder/test_layer_transparency_on_the_advance.rb.
class TestLayerTransparencyOnTheAdvanceCartridge < Minitest::Test
  include LayerTransparencyGames

  private def console(program, x, y, name, frames: 6)
    assert_emulator_loads_rom(assemble_rom(program, name: name), frames: frames).pixel_gba(x, y)
  end

  # A fade PLACED in the stack takes the blend and gives it back on the console too.
  def test_a_fade_placed_in_the_stack_takes_the_blend_and_gives_it_back_on_the_console
    on_console = console(placed_fade_program(0, 25), *SCENERY_XY, "FADPLC")

    assert_equal on_console, console(placed_fade_program(50, 25), *SCENERY_XY, "FADPL2")
    assert_equal HALF_WHITE_OVER_RED, console(placed_fade_program(50, 0), *SCENERY_XY, "FADPL3")
  end

  # ...and the console draws the same walk. Compared to the interpreter's own frames
  # rather than to written-down colors, so this cannot pass by agreeing with a table.
  def test_the_console_walks_the_same_amounts
    rom = assemble_rom(clearing_program, name: "FOG")
    oracle = walked(clearing_program, 10)
    seen = (1..10).map { |f| assert_emulator_loads_rom(rom, frames: f + CONSOLE_LAG).pixel_gba(*SCENERY_XY) }

    assert_equal oracle, seen
  end

  # ...and both backends land on the SAME faded mix, which is the assertion that can
  # catch a blend done in the wrong order. Darkening each color and then mixing them is
  # not quite darkening the mix — the two truncate in different places — so this would
  # fail by a step if either side moved its colors at the wrong moment.
  def test_the_two_backends_agree_on_a_see_through_layer_under_a_fade
    %i[scenery sprite].each do |kind|
      assert_equal shown(faded_program(kind, 50, 25), *faded_xy(kind)),
                   console(faded_program(kind, 50, 25), *faded_xy(kind), "FADMIX"),
                   "the backends disagree about the #{kind} layer under a fade"
    end
  end

  def test_the_console_agrees_about_a_fade_to_white
    assert_equal shown(faded_program(:scenery, 50, 25, toward: :white), *SCENERY_XY),
                 console(faded_program(:scenery, 50, 25, toward: :white), *SCENERY_XY, "FADWHT")
  end

  # ...and a fade of nothing is a lifted fade on the console as well.
  def test_a_lifted_fade_leaves_the_layer_see_through_on_the_console
    %i[scenery sprite].each do |kind|
      assert_equal HALF_WHITE_OVER_RED, console(faded_program(kind, 50, 0), *faded_xy(kind), "FADOFF"),
                   "the #{kind} layer"
    end
  end

  def test_a_tint_leaves_the_layer_see_through_on_the_console
    assert_equal shown(tinted_program(50, 50), *SCENERY_XY),
                 console(tinted_program(50, 50), *SCENERY_XY, "TNTSEE"),
                 "the two backends disagree about a tint over a see-through layer"
  end

  # The scene before the dive, which sees through nothing, is drawn solid on the console too.
  def test_a_scene_that_sees_through_nothing_is_drawn_solid_on_the_console
    green = VBlank::Graphics::Color.resolve(:green)

    assert_equal green, console(scenes_that_take_turns, *SCENERY_XY, "SCNSLD", frames: 3),
                 "the banner scene is blended on the console"
  end
end
