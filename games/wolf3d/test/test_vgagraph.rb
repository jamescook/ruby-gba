# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Reading VGAGRAPH: the picture table, the pictures themselves, and the two alphabets.
#
# Against OUR OWN release first, where every byte was chosen and a wrong answer is a wrong
# answer rather than something that merely looks odd — and then against a real copy, where
# what can be checked is that the counts and the shapes are the ones that release has.
class TestVgagraph < Minitest::Test
  include Wolf3DTest

  Release = Wolf3D::Fixture::Release
  Vgagraph = Wolf3D::Vgagraph

  def fixture
    graph, dictionary, head = Release.new.send(:vgagraph)
    Vgagraph.new(graph: graph, dictionary: dictionary, head: head, set: "WL1")
  end

  # How many pictures there are is not written down anywhere. It comes out of the picture
  # table's own length: four bytes a picture, a width and a height.
  def test_the_picture_table_says_how_many_pictures_there_are_and_how_big
    vg = fixture

    assert_equal Release::PICTURES.length, vg.picture_count
    Release::PICTURES.each_with_index { |wh, i| assert_equal wh, vg.size(i) }
  end

  def test_the_chunks_are_the_table_then_the_fonts_then_the_pictures
    vg = fixture

    assert_equal Vgagraph::FIRST_PICTURE + Release::PICTURES.length, vg.chunk_count
  end

  # THE ONE UNSCRAMBLING THIS FILE NEEDS. A picture is stored as four quarter-width
  # pictures stacked, each holding every fourth column. Every pixel of the fixture says
  # where it came from — its row in the top four bits, its column in the bottom four — so
  # a reader that shuffled the banks comes back with a number that names the bank it
  # really read.
  def test_a_picture_comes_back_out_of_its_four_banks_in_order
    picture = fixture.picture(0)
    width, height = Release::PICTURES.first

    assert_equal width, picture.width
    assert_equal height, picture.height
    height.times do |y|
      width.times do |x|
        assert_equal Release.new.send(:picture_pixel, x, y), picture[x, y],
                     "pixel (#{x},#{y}) came from the wrong place"
      end
    end
  end

  def test_a_second_picture_of_a_different_shape_reads_too
    picture = fixture.picture(1)

    assert_equal Release::PICTURES.last, [picture.width, picture.height]
    assert_equal picture.width * picture.height, picture.pixels.length
    assert_equal picture[15, 1], picture.pixels.last
  end

  def test_asking_for_a_picture_that_is_not_there_is_a_friendly_error
    err = assert_raises(IndexError) { fixture.picture(99) }
    assert_match(/no picture 99/, err.message)
  end

  # Both alphabets, not just the small one — the menus are written in the big one.
  def test_both_alphabets_read_back_with_their_own_heights
    vg = fixture

    assert_equal Release::FONTS[0][:height], vg.font(0).height
    assert_equal Release::FONTS[1][:height], vg.font(1).height
    assert_equal 2, vg.fonts.length
  end

  # PROPORTIONAL: every character carries its own width. A reader that took one width for
  # the whole font would find the second character in the wrong place.
  def test_each_character_keeps_its_own_width
    font = fixture.font(0)

    assert_equal 1, font.width("I")
    assert_equal 3, font.width("M")
    assert_equal 0, font.width("Z"), "a character nobody drew"
    assert_equal %w[I M].map(&:ord), font.codes
  end

  def test_a_glyph_reads_back_as_the_letter_that_went_in
    font = fixture.font(0)
    ink = Release::FONT_INK

    assert_equal [[ink, 0, ink], [ink, ink, ink], [ink, 0, ink]], font.rows("M")
    assert_equal [[ink], [ink], [ink]], font.rows("I")
    assert_empty font.rows("Z")
  end

  # The door to the framework: an alphabet handed over as pictures of its letters, which
  # is the only way a font that already exists can arrive. Nobody retypes one.
  def test_the_alphabet_registers_as_a_font_and_writes_with_it
    glyphs = fixture.font(0).glyphs

    assert_equal %w[I M], glyphs.keys.sort

    b = Builder.new
    b.instance_eval do
      screen :bitmap
      font :wolf, glyphs: glyphs
      draw_text "M", 10, 10, :white
    end
    registered = RubyGBA::Fonts.get(:wolf)

    assert_equal 3, registered.height
    assert_equal 1, registered.glyph_width("I")
    assert_equal 3, registered.glyph_width("M")
  ensure
    RubyGBA::Fonts.instance_variable_get(:@registry).delete(:wolf)
  end

  def test_a_font_that_is_not_there_is_a_friendly_error
    err = assert_raises(IndexError) { fixture.font(2) }
    assert_match(/no font 2/, err.message)
  end

  # --- a file that is wrong, rather than a file that is missing --------------------

  def test_a_dictionary_of_the_wrong_size_is_a_friendly_error
    graph, dictionary, head = Release.new.send(:vgagraph)
    err = assert_raises(ArgumentError) do
      Vgagraph.new(graph: graph, dictionary: dictionary[0, 100], head: head)
    end
    assert_match(/VGADICT/, err.message)
  end

  def test_a_head_that_is_not_whole_offsets_is_a_friendly_error
    graph, dictionary, head = Release.new.send(:vgagraph)
    err = assert_raises(ArgumentError) do
      Vgagraph.new(graph: graph, dictionary: dictionary, head: head + "\x00")
    end
    assert_match(/VGAHEAD/, err.message)
  end

  def test_a_head_pointing_past_the_end_of_the_art_is_a_friendly_error
    graph, dictionary, head = Release.new.send(:vgagraph)
    err = assert_raises(ArgumentError) do
      Vgagraph.new(graph: graph[0, 20], dictionary: dictionary, head: head)
    end
    assert_match(/different releases, or one is damaged/, err.message)
  end

  def test_art_cut_short_is_a_friendly_error
    graph, dictionary, head = Release.new.send(:vgagraph)
    # Say the file is as long as it was, and hand over one that is not.
    short = graph[0, graph.bytesize - 40] + ("\x00" * 40)
    vg = Vgagraph.new(graph: short, dictionary: dictionary, head: head)

    assert_raises(ArgumentError) { vg.picture(Release::PICTURES.length - 1) }
  end

  # A chunk read at the wrong offset decodes to plausible rubbish, so a font is checked
  # against its own arithmetic: the widths of every character times the one height has to
  # come to the lettering that follows the heading.
  def test_a_chunk_that_is_not_a_font_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Vgagraph::Font.new("\x03\x00" + ("\x00" * (256 * 3)) + ("\x00" * 8))
    end
    assert_match(/is not a font/, err.message)
  end

  # --- against a real copy of the game ---------------------------------------------

  def real = Wolf3D::Vgagraph.from(game_data_or_skip)

  def test_a_real_release_reads_its_picture_table
    vg = real

    assert_operator vg.picture_count, :>, 100, "a release carries a hundred-odd pictures"
    vg.picture_count.times do |i|
      width, height = vg.size(i)
      assert_equal 0, width % 4, "picture #{i} is #{width} wide, which cannot be stored"
      assert_operator height, :>, 0
    end
  end

  # THE ONE THE STATUS BAR IS BUILT ON. Named rather than numbered, because a number here
  # says nothing about what it is, and the numbers differ from one release to the next.
  def test_a_named_picture_is_the_size_that_release_draws_it
    vg = real
    skip "names are not known for #{vg.set}" unless vg.names.include?(:status_bar)

    assert_equal [320, 40], vg.size(:status_bar), "the steel plate along the bottom"
    assert_equal [320, 200], vg.size(:title), "the title screen fills the screen"
    assert_equal [8, 16], vg.size(:digit_0), "a numeral on the bar"
    assert_equal [24, 32], vg.size(:face_1a), "the face that watches you"
  end

  # WHERE THE EXACT PROOF LIVES, so nobody reads more into this one than it says: the
  # unscrambling is checked pixel by pixel against OUR release above, where every pixel
  # names its own row and column. Nothing here can do that — a real picture has no
  # reference to hold it against, and a picture that came out of its banks wrong is not
  # noise but the same picture with its columns shuffled, which counts the same colours.
  #
  # What this asks is that a real one comes through the same path whole: the right count
  # of pixels, a border that runs the width of the plate, and more than one colour.
  def test_a_real_picture_comes_out_whole
    vg = real
    skip "names are not known for #{vg.set}" unless vg.names.include?(:status_bar)

    bar = vg.picture(:status_bar)

    assert_equal 320 * 40, bar.pixels.length
    assert_equal 1, bar.rows.first.uniq.length, "the plate's top row is its border"
    assert_operator bar.pixels.uniq.length, :>, 8, "a flat picture would prove nothing"
  end

  # THE TWO KEYS ARE THE SAME SHAPE and differ only in their ink, so nothing about the
  # picture says which is which — the names come from the order the release packed them in,
  # which is exactly the kind of thing to get backwards.
  #
  # What makes them checkable is the metal. Take away every colour the EMPTY slot draws and
  # what is left is the key itself: one is drawn in yellows and warm highlights, every one
  # of them redder than it is blue, and the other in greys and cold highlights, not one of
  # them redder than it is blue. A table with the two the wrong way round swaps that.
  def test_the_keys_are_named_for_the_metal_they_are_drawn_in
    vg = real
    skip "names are not known for #{vg.set}" unless vg.names.include?(:gold_key)

    slot = vg.picture(:no_key).pixels.uniq
    gold = vg.picture(:gold_key).pixels.uniq - slot
    silver = vg.picture(:silver_key).pixels.uniq - slot

    refute_empty gold
    refute_empty silver
    assert(gold.all? { |ink| warm?(ink) }, "the gold key is drawn in #{cool(gold).inspect}")
    assert(silver.none? { |ink| warm?(ink) }, "the silver key is drawn in #{gold_ink(silver).inspect}")
  end

  def warm?(ink)
    red, _green, blue = Wolf3D::Palette::CHANNELS[ink]
    red > blue
  end

  def cool(inks) = inks.reject { |ink| warm?(ink) }
  def gold_ink(inks) = inks.select { |ink| warm?(ink) }

  def test_a_real_release_carries_two_proportional_alphabets
    vg = real

    vg.fonts.each_with_index do |font, n|
      assert_operator font.height, :>, 0, "font #{n} has no height"
      assert_operator font.codes.length, :>, 40, "font #{n} draws too few characters"
      assert_operator font.width("M"), :>, font.width("I"), "font #{n} is not proportional"
      assert_equal font.height, font.rows("A").length
    end
    refute_equal vg.font(0).height, vg.font(1).height, "the two alphabets are different sizes"
  end

  def test_a_real_alphabet_registers_as_a_font
    glyphs = real.font(0).glyphs

    assert_includes glyphs.keys, "A"
    assert_includes glyphs.keys, "0"

    b = Builder.new
    b.instance_eval { font :wolf_small, glyphs: glyphs }
    registered = RubyGBA::Fonts.get(:wolf_small)

    assert_equal real.font(0).height, registered.height
    assert_operator registered.text_width("HELLO"), :>, 0
    refute_equal 0, registered.glyph_pixels("A"), "the letter A must light some pixels"
  ensure
    RubyGBA::Fonts.instance_variable_get(:@registry).delete(:wolf_small)
  end
end
