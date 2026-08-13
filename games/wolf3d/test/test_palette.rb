# frozen_string_literal: true

require_relative "test_helper"

class TestPalette < Minitest::Test
  include Wolf3DTest

  Palette = Wolf3D::Palette

  def test_the_game_palette_is_two_hundred_and_fifty_six_colours_in_range
    palette = Palette.game

    assert_equal 256, palette.length
    assert_equal 256, palette.channels.length
    assert(palette.channels.flatten.all? { |value| value.between?(0, Palette::CHANNEL_MAX) })
  end

  # Two colours whose values are not arbitrary. The first sixteen are the standard EGA set every
  # DOS program of the period carried, and the last is the magenta Wolfenstein treats as
  # see-through — so both ends of the table can be checked against something known.
  def test_it_starts_with_the_ega_black_and_ends_with_the_see_through_magenta
    palette = Palette.game

    assert_equal [0, 0, 0], palette.channels.first
    assert_equal [0, 0, 42], palette.channels[1]
    assert_equal [38, 0, 34], palette.channels.last
  end

  # Entries 16 to 20 step down by three and four. Nothing else in the table looks like it, which
  # is what made it findable in the first place.
  def test_the_grey_ramp_is_where_it_belongs
    assert_equal [[59, 59, 59], [55, 55, 55], [52, 52, 52], [48, 48, 48], [45, 45, 45]],
                 Palette.game.channels[16, 5]
  end

  # A VGA channel held six bits; the console wants five, so it is a shift rather than a scale.
  def test_the_colours_are_widened_to_what_the_console_wants
    palette = Palette.game

    assert_equal RubyGBA::Color.rgb(0, 0, 21), palette[1], "0,0,42 in six bits is 0,0,21 in five"
    assert_equal RubyGBA::Color.rgb(19, 0, 17), palette[255]
  end

  def test_a_palette_of_the_wrong_size_is_refused
    assert_raises(ArgumentError) { Palette.new([[0, 0, 0]]) }
  end
end
