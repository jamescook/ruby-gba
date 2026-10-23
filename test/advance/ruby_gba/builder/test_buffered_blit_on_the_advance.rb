# frozen_string_literal: true

require "test_helper"
require "differential"

# The tests of test/ruby_gba/builder/test_buffered_blit.rb whose games paint their screen in more
# colours than a painted Game Boy Color screen holds — the picture here has sixteen, one per
# pixel — so they play on the Advance's runs alone. The rest are in that file.
#
# Drawing a whole PICTURE on the tear-free screen. The promise is the one every other draw makes
# here: the same picture at the same place with the same clipping, whichever screen it is drawn
# on.
class TestBufferedBlitOnTheAdvance < Minitest::Test
  include RubyGBA::IR::Build
  include Differential

  # A picture whose every pixel says WHERE IT CAME FROM — its column in the red channel
  # and its row in the green — so a pixel read from the wrong place lands a colour that
  # names the place it really came from. Both axes matter: a picture of stripes would
  # hide a row read at the wrong offset ACROSS, which is exactly the mistake a clipped
  # left edge makes.
  #
  # Four wide, because the screen moves two pixels at a time and an odd width could not
  # be copied whole.
  SIDE = 4

  private def art_pixel(col, row) = Color.rgb(4 + (col * 6), 4 + (row * 6), 20)

  private def stripes
    pixels = (0...SIDE).flat_map { |row| (0...SIDE).map { |col| art_pixel(col, row) } }
    bitmap(:stripes, width: SIDE, height: SIDE, pixels: pixels.pack("v*"))
  end

  # The same drawing on either screen. +buffered+ picks which.
  private def blit_program(x, y, buffered:)
    program(
      screen(:bitmap, buffered: buffered),
      clear_screen(:black),
      stripes,
      blit(:stripes, x, y),
      wait_vblank,
      halt,
    )
  end

  private def pixels_of(prog) = game_player.run(prog).screen

  # --- it draws at all ------------------------------------------------------------

  def test_a_picture_draws_on_the_tear_free_screen
    s = pixels_of(blit_program(100, 40, buffered: true))
    SIDE.times do |row|
      SIDE.times do |col|
        assert_equal art_pixel(col, row), s.pixel(100 + col, 40 + row),
                     "(#{col},#{row}) of the picture landed somewhere else"
      end
    end
    assert_equal Color.resolve(:black), s.pixel(99, 40), "nothing left of the picture"
    assert_equal Color.resolve(:black), s.pixel(104, 40), "nothing right of it"
  end

  # Every pixel of the screen, both backends. A picture is exactly the kind of drawing
  # where a handful of spot checks can miss a row landing one place over.
  def test_both_backends_draw_the_whole_screen_the_same
    assert_backends_agree(blit_program(100, 40, buffered: true), frames: 2)
  end

  # --- clipped at every edge, the same as the direct screen ------------------------

  # Half off each edge, and one wholly outside. The comparison is against the DIRECT
  # screen running the same program, which is the promise: same picture, same place,
  # same clipping, only the screen differs.
  EDGES = [
    [-2, 40, "half off the left"],
    [238, 40, "half off the right"],
    [100, -2, "half off the top"],
    [100, 158, "half off the bottom"],
    [-8, 40, "wholly off the left"],
    [244, 40, "wholly off the right"],
    [100, -8, "wholly above"],
    [100, 168, "wholly below"],
  ].freeze

  def test_clipping_matches_the_direct_colour_screen
    EDGES.each do |x, y, what|
      direct = pixels_of(blit_program(x, y, buffered: false))
      paged = pixels_of(blit_program(x, y, buffered: true))
      differing = (0...240).to_a.product((0...160).to_a).reject do |px, py|
        direct.pixel(px, py) == paged.pixel(px, py)
      end
      assert_empty differing.first(5), "#{what}: the two screens drew different pixels"
    end
  end

  def test_the_console_clips_a_picture_the_same_way
    EDGES.each do |x, y, what|
      oracle = pixels_of(blit_program(x, y, buffered: true))
      rom = assemble_rom(blit_program(x, y, buffered: true), name: "BCLIP")
      v = assert_emulator_loads_rom(rom, frames: 6)
      # The row that shows, wherever it landed, plus the pixel just past each edge of it.
      (0...160).step(1) do |py|
        (0...240).step(1) do |px|
          next unless oracle.pixel(px, py) != Color.resolve(:black)

          assert_equal oracle.pixel(px, py), v.pixel_gba(px, py),
                       "#{what}: (#{px},#{py}) differs from the oracle"
        end
      end
    end
  end

  # A row wrapping onto its neighbour is the bug an edge clip actually has, so ask about
  # the pixel a wrap would land on rather than only about the ones inside.
  def test_a_clipped_row_does_not_wrap_onto_the_next_line
    s = pixels_of(blit_program(238, 40, buffered: true))
    assert_equal art_pixel(0, 0), s.pixel(238, 40), "the part that fits still draws"
    assert_equal Color.resolve(:black), s.pixel(0, 41), "the cut-off part must not wrap"
    assert_equal Color.resolve(:black), s.pixel(1, 41)
  end

  # THE LEFT EDGE IS THE ONE THAT NEEDS A PICTURE VARYING ACROSS, and it is worth its own
  # test rather than only the whole-screen comparison. A picture hanging off the left must
  # show its RIGHT-HAND columns at the screen's left, because the columns before them are
  # the ones cut off — and a reader that forgot to skip them would show the left-hand
  # columns there instead, which is a picture in the right place made of the wrong pixels.
  def test_a_picture_off_the_left_shows_the_columns_that_survive
    s = pixels_of(blit_program(-2, 40, buffered: true))
    SIDE.times do |row|
      assert_equal art_pixel(2, row), s.pixel(0, 40 + row), "column 2 belongs at the screen's edge"
      assert_equal art_pixel(3, row), s.pixel(1, 40 + row), "column 3 beside it"
    end
  end

  # INSIDE AN AREA the edges move, and that is what makes an edge off by one visible at
  # all. A row one past the bottom of the SCREEN lands in memory nobody ever shows, so
  # no pixel can tell you about it; a row one past the bottom of an AREA lands in plain
  # sight, on a part of the screen the area said to leave alone.
  private def area_program(x, y, buffered:)
    program(
      screen(:bitmap, buffered: buffered),
      clear_screen(:black),
      stripes,
      inside(0, 0, 120, 100, blit(:stripes, x, y)),
      wait_vblank,
      halt,
    )
  end

  # Straddling every edge of the area in turn: the part inside draws, the part outside
  # does not, and what is outside is still on screen so a mistake shows.
  AREA_EDGES = [[100, 98, "over the area's bottom"], [118, 40, "over its right side"]].freeze

  def test_a_picture_is_cut_at_the_edges_of_an_area
    AREA_EDGES.each do |x, y, what|
      s = pixels_of(area_program(x, y, buffered: true))
      SIDE.times do |row|
        SIDE.times do |col|
          px = x + col
          py = y + row
          want = px < 120 && py < 100 ? art_pixel(col, row) : Color.resolve(:black)
          assert_equal want, s.pixel(px, py), "#{what}: (#{px},#{py})"
        end
      end
    end
  end

  # A column the game works out AS an even number is fine, because that can be proved.
  def test_a_column_the_game_works_out_but_is_always_even_draws
    prog = program(
      screen(:bitmap, buffered: true),
      clear_screen(:black),
      set(:col, 50),
      stripes,
      blit(:stripes, binop(:*, var_ref(:col), int(2)), int(40)),
      wait_vblank,
      halt,
    )
    s = game_player.run(prog).screen
    assert_equal art_pixel(0, 0), s.pixel(100, 40)
    assemble_rom(prog, name: "BEVEN") # ...and it lowers rather than raising
  end
end
