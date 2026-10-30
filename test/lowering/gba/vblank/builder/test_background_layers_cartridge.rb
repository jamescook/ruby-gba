# frozen_string_literal: true

require "test_helper"
require "console/gba/vblank/builder/test_background_layers_on_the_advance"

# STACKED BACKGROUNDS ON THE ADVANCE'S CARTRIDGE, read in the emulator: the layers really
# composite and parallax-scroll, and black covers where the picture says it does. What every run
# of an Advance game shows is in test/console/gba/vblank/builder/test_background_layers_on_the_advance.rb.
class TestBackgroundLayersCartridge < Minitest::Test
  include BackgroundLayersGames

  def test_layers_compose_on_the_console
    v = assert_emulator_loads_rom(rom_for(two_layers(0, 0)), frames: 3)
    assert v.green?(44, 44), "far green shows through the empty near layer, got 0x#{format('%04X', v.pixel_gba(44, 44))}"
    assert v.red?(84, 44),   "near red sits in front, got 0x#{format('%04X', v.pixel_gba(84, 44))}"
    assert v.blue?(100, 100), "the near layer is see-through elsewhere, got 0x#{format('%04X', v.pixel_gba(100, 100))}"
  end

  def test_layers_parallax_on_the_console
    v = assert_emulator_loads_rom(rom_for(two_layers(20, 40)), frames: 3)
    assert v.green?(24, 44), "far slid 20px, got 0x#{format('%04X', v.pixel_gba(24, 44))}"
    assert v.red?(44, 44),   "near slid 40px — twice as far (parallax), got 0x#{format('%04X', v.pixel_gba(44, 44))}"
  end

  def test_black_at_a_place_covers_on_a_turning_background
    assert_equal 0x0000, assert_emulator_loads_rom(rom_for(black_by_place_turning), frames: 3).pixel_gba(2, 2)
  end

  # Art given as place numbers says where it is see-through itself (place 0), so black at
  # any other place is solid. Art drawn in colours has only the backdrop colour to say
  # "nothing here", so black drawn that way lets the layer behind through.
  def test_black_at_a_place_covers_and_black_drawn_as_a_colour_shows_through
    assert_equal 0x0000, assert_emulator_loads_rom(rom_for(black_by_place), frames: 3).pixel_gba(2, 2)
    assert_equal RED, assert_emulator_loads_rom(rom_for(black_drawn_in_characters), frames: 3).pixel_gba(2, 2)
  end

  def test_black_painted_at_a_place_covers
    assert_equal 0x0000, assert_emulator_loads_rom(rom_for(black_painted), frames: 3).pixel_gba(2, 2)
  end
end
