# frozen_string_literal: true

require "test_helper"
require "differential"

# Drawing a whole PICTURE on the tear-free screen.
#
# The tear-free screen holds a NUMBER per pixel, picking a colour out of a shared table,
# where the direct screen holds a whole colour. So a picture has to be shipped a second
# way — as numbers — and copied in a row at a time. And the screen takes two pixels at
# once and will not take one, so a row copies straight in only when it starts on an even
# column: that is the same rule the rectangle fills already live by.
#
# THE PROMISE IS THE ONE EVERY OTHER DRAW MAKES HERE: the same picture at the same place
# with the same clipping, whichever screen it is drawn on. So most of these run the same
# program on both screens and demand the same pixels, rather than pinning numbers that
# only say what today's code does.
class TestBufferedBlit < Minitest::Test
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

  def art_pixel(col, row) = Color.rgb(4 + (col * 6), 4 + (row * 6), 20)

  def stripes
    pixels = (0...SIDE).flat_map { |row| (0...SIDE).map { |col| art_pixel(col, row) } }
    bitmap(:stripes, width: SIDE, height: SIDE, pixels: pixels.pack("v*"))
  end

  # The same drawing on either screen. +buffered+ picks which.
  def blit_program(x, y, buffered:)
    program(
      screen(:bitmap, buffered: buffered),
      clear_screen(:black),
      stripes,
      blit(:stripes, x, y),
      wait_vblank,
      halt,
    )
  end

  def pixels_of(prog) = Reference.new.run(prog).screen

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

  def test_the_console_draws_the_same_picture
    rom = assemble_rom(blit_program(100, 40, buffered: true), name: "BBLIT")
    v = assert_gemba_loads_rom(rom, frames: 6)
    SIDE.times do |row|
      SIDE.times do |col|
        assert_equal art_pixel(col, row), v.pixel_gba(100 + col, 40 + row),
                     "console: (#{col},#{row}) of the picture landed somewhere else"
      end
    end
    assert v.pixel_is?(99, 40, :black), "console: nothing left of the picture"
    assert v.pixel_is?(104, 40, :black), "console: nothing right of it"
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
      v = assert_gemba_loads_rom(rom, frames: 6)
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

  def test_the_console_shows_the_surviving_columns_too
    rom = assemble_rom(blit_program(-2, 40, buffered: true), name: "BLEFT")
    v = assert_gemba_loads_rom(rom, frames: 6)
    SIDE.times do |row|
      assert_equal art_pixel(2, row), v.pixel_gba(0, 40 + row), "console: column 2 belongs at the edge"
      assert_equal art_pixel(3, row), v.pixel_gba(1, 40 + row), "console: column 3 beside it"
    end
  end

  # INSIDE AN AREA the edges move, and that is what makes an edge off by one visible at
  # all. A row one past the bottom of the SCREEN lands in memory nobody ever shows, so
  # no pixel can tell you about it; a row one past the bottom of an AREA lands in plain
  # sight, on a part of the screen the area said to leave alone.
  def area_program(x, y, buffered:)
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

  def test_the_console_cuts_a_picture_at_an_area_the_same_way
    AREA_EDGES.each do |x, y, what|
      rom = assemble_rom(area_program(x, y, buffered: true), name: "BAREA")
      v = assert_gemba_loads_rom(rom, frames: 6)
      SIDE.times do |row|
        SIDE.times do |col|
          px = x + col
          py = y + row
          want = px < 120 && py < 100 ? art_pixel(col, row) : Color.resolve(:black)
          assert_equal want, v.pixel_gba(px, py), "console: #{what}: (#{px},#{py})"
        end
      end
    end
  end

  # --- what this cannot draw yet, said plainly -------------------------------------

  def test_an_odd_column_is_a_friendly_error
    err = assert_raises(RubyGBA::IR::Backends::GBA::LoweringError) do
      assemble_rom(blit_program(101, 40, buffered: true), name: "BODD")
    end
    assert_match(/even/, err.message)
    assert_match(/101/, err.message)
  end

  # A column the game works out cannot be proved even, and drawing it at the wrong place
  # (or not at all) would be a silent wrong picture. Say so while building instead.
  def test_a_column_that_cannot_be_proved_even_is_a_friendly_error
    prog = program(
      screen(:bitmap, buffered: true),
      set(:where, 100),
      stripes,
      blit(:stripes, var_ref(:where), int(40)),
      halt,
    )
    err = assert_raises(RubyGBA::IR::Backends::GBA::LoweringError) { assemble_rom(prog, name: "BVAR") }
    assert_match(/even/, err.message)
  end

  # ...and a column it works out AS an even number is fine, because that can be proved.
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
    s = Reference.new.run(prog).screen
    assert_equal art_pixel(0, 0), s.pixel(100, 40)
    assemble_rom(prog, name: "BEVEN") # ...and it lowers rather than raising
  end

  def test_a_see_through_picture_says_it_is_not_drawn_here_yet
    prog = program(
      screen(:bitmap, buffered: true),
      clear_screen(:black),
      bitmap(:ghost, width: 4, height: 2,
                     pixels: ([Color.resolve(:red)] * 4 + [0x7C1F] * 4).pack("v*"), transparent: 0x7C1F),
      blit(:ghost, 100, 40),
      halt,
    )
    err = assert_raises(RubyGBA::IR::Backends::GBA::LoweringError) { assemble_rom(prog, name: "BGHOST") }
    assert_match(/see-through/, err.message)
  end
end
