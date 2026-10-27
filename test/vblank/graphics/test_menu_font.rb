# frozen_string_literal: true

require "test_helper"

# The letters the window menu is written in, read from the pictures tools/make_menu_font.rb drew.
class TestMenuFont < Minitest::Test
  MenuFont = VBlank::Graphics::MenuFont

  # Every letter has its place in the picture at both densities, inside it.
  def test_every_letter_is_in_the_picture_at_both_densities
    font = MenuFont.load
    [1, 2].each do |density|
      atlas = font.atlas(density)
      assert_equal atlas.width * atlas.height, atlas.alpha.bytesize

      font.layout("Resume ✓ × … AZaz09%()", 0, 0, density).each do |letter|
        x, y, wide, high = letter.from
        assert_operator x + wide, :<=, atlas.width
        assert_operator y + high, :<=, atlas.height
        covered = (0...high).sum { |row| atlas.alpha.byteslice(((y + row) * atlas.width) + x, wide).bytes.sum }
        assert_operator covered, :>, 0, "the picture has nothing where a letter is"
      end
    end
  end

  def test_a_space_is_room_and_no_letter
    font = MenuFont.load

    assert_empty font.layout(" ", 0, 0, 1)
    assert_operator font.width(" ", 1), :>, 0
    assert_operator font.width("a b", 1), :>, font.width("ab", 1)
  end

  # A pair the font sets closer than its letters' own widths, as A and V are.
  def test_a_kerned_pair_sits_closer
    font = MenuFont.load

    assert_operator font.width("AV", 1), :<, font.width("A", 1) + font.width("V", 1)
  end

  # Words start where they are asked to, and a letter further on in them is further right.
  def test_letters_go_left_to_right_from_where_the_words_start
    letters = MenuFont.load.layout("Hi", 100, 50, 1)

    assert_equal 2, letters.size
    assert_operator letters[0].to[0], :>=, 100
    assert_operator letters[0].to[1], :>=, 50
    assert_operator letters[1].to[0], :>, letters[0].to[0]
  end

  # A letter the font does not have is written as a question mark, not left out.
  def test_a_letter_the_font_lacks_is_a_question_mark
    font = MenuFont.load

    assert_equal font.layout("?", 0, 0, 1), font.layout("ж", 0, 0, 1)
  end

  # Twice the density is twice the pixels, near enough: the letters are drawn at each size by the
  # font itself, so their widths round a little differently.
  def test_twice_the_density_is_about_twice_as_wide_and_tall
    font = MenuFont.load

    assert_in_delta font.width("Fast forward", 1) * 2, font.width("Fast forward", 2), 4
    assert_in_delta font.line_height(1) * 2, font.line_height(2), 1
  end

  # A screen between the two densities is written from the bigger picture, scaled down to it.
  def test_a_density_between_the_two_is_drawn_from_the_bigger_picture
    font = MenuFont.load
    letter = font.layout("H", 0, 0, 1.5).first

    assert_equal 2, font.atlas(1.5).density
    assert_equal (letter.from[2] * 0.75).round, letter.to[2]
  end
end
