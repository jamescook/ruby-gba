# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_buffered_blit"

# Drawing a whole PICTURE on the tear-free screen, read back off the Advance's own cartridge in
# the emulator: the same picture at the same place with the same clipping as the interpreter
# draws. The picture and the program that draws it are kept in BufferedBlitGames in
# test/all/vblank/builder/test_buffered_blit.rb, with the tests every run plays; the ones only
# the Advance's runs play are in test/console/gba/vblank/builder/test_buffered_blit_on_the_advance.rb.
class TestBufferedBlitCartridge < Minitest::Test
  include VBlank::IR::Build
  include BufferedBlitGames

  # --- it draws at all ------------------------------------------------------------

  def test_the_console_draws_the_same_picture
    rom = assemble_rom(blit_program(100, 40, buffered: true), name: "BBLIT")
    v = assert_emulator_loads_rom(rom, frames: 6)
    SIDE.times do |row|
      SIDE.times do |col|
        assert_equal art_pixel(col, row), v.pixel_gba(100 + col, 40 + row),
                     "console: (#{col},#{row}) of the picture landed somewhere else"
      end
    end
    assert v.pixel_is?(99, 40, :black), "console: nothing left of the picture"
    assert v.pixel_is?(104, 40, :black), "console: nothing right of it"
  end

  # --- clipped at the left edge ------------------------------------------------------

  # A picture hanging off the left must show its RIGHT-HAND columns at the screen's left,
  # because the columns before them are the ones cut off.
  def test_the_console_shows_the_surviving_columns_too
    rom = assemble_rom(blit_program(-2, 40, buffered: true), name: "BLEFT")
    v = assert_emulator_loads_rom(rom, frames: 6)
    SIDE.times do |row|
      assert_equal art_pixel(2, row), v.pixel_gba(0, 40 + row), "console: column 2 belongs at the edge"
      assert_equal art_pixel(3, row), v.pixel_gba(1, 40 + row), "console: column 3 beside it"
    end
  end

  # --- clipped at every edge, the same as the interpreter --------------------------

  # Half off each edge, and one wholly outside.
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

  def test_the_console_clips_a_picture_the_same_way
    EDGES.each do |x, y, what|
      oracle = game_player.run(blit_program(x, y, buffered: true)).screen
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

  def test_the_console_cuts_a_picture_at_an_area_the_same_way
    AREA_EDGES.each do |x, y, what|
      rom = assemble_rom(area_program(x, y, buffered: true), name: "BAREA")
      v = assert_emulator_loads_rom(rom, frames: 6)
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
end
