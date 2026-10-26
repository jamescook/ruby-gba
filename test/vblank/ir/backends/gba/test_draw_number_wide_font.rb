# frozen_string_literal: true

require "test_helper"

# A live number in a font wider than eight pixels — a game's own big letters. The cartridge
# draws a live digit with one shared routine that walks a table of the ten glyphs, a row of bits
# at a time; a row wider than a byte is kept as a whole word, so a wide font is drawn by that
# routine too, rather than as ten pieces of text with an instruction for every lit pixel.
class TestDrawNumberWideFont < Minitest::Test
  LETTERS = VBlank::Graphics::Fonts.default

  # The built-in figures with +pad+ blank columns added on the right, so the same digits come
  # out a font as wide as +LETTERS.width + pad+.
  private def padded_figures(pad)
    (0..9).to_h do |k|
      rows = Array.new(LETTERS.height) { Array.new(LETTERS.width + pad, 0) }
      LETTERS.each_pixel(k.to_s) { |x, y| rows[y][x] = 1 }
      [k.to_s, rows]
    end
  end

  # The built-in figures with every pixel made a 3 by 3 square: fifteen wide.
  private def big_figures
    (0..9).to_h do |k|
      rows = Array.new(LETTERS.height * 3) { Array.new(LETTERS.width * 3, 0) }
      LETTERS.each_pixel(k.to_s) { |x, y| 9.times { |n| rows[(y * 3) + (n / 3)][(x * 3) + (n % 3)] = 1 } }
      [k.to_s, rows]
    end
  end

  # The same number drawn live (from a variable) and fixed (worked out when the game is built),
  # at an odd column, so the tear-free screen's two pixels to a halfword are both exercised.
  #
  # The plain screen has one picture, which the console shows while it is being drawn, so there
  # it is drawn once and the game stops: redrawn every frame, the screen is caught half painted.
  # The tear-free screen only ever shows a finished picture, and needs a game loop to show one.
  private def two_ways_program(screen_options, glyphs)
    b = Builder.new
    b.instance_eval do
      screen :bitmap, **screen_options
      font :big, glyphs: glyphs, spacing: 3
      var :score, 1987
      both = lambda do
        clear_screen :blue
        draw_number :score, 41, 20, :white, digits: 4, font: :big
        draw_number 1987, 41, 60, :white, digits: 4, font: :big
      end
      if screen_options[:tear_free]
        game_loop { both.call }
      else
        both.call
        halt
      end
    end
    b.finalize_program
    b.program
  end

  private def assert_live_matches_fixed(screen_options)
    program = two_ways_program(screen_options, big_figures)
    rom = ROM.assemble(GBA.new.lower(program), title: "WIDENUM", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 4)

    lit = 0
    (0...(4 * 18)).each do |dx|
      (0...21).each do |dy|
        assert_equal v.pixel_gba(41 + dx, 60 + dy), v.pixel_gba(41 + dx, 20 + dy),
                     "live and fixed digits differ at column #{dx}, row #{dy}"
        lit += 1 if v.white?(41 + dx, 20 + dy)
      end
    end
    assert_operator lit, :>, 100, "the digits drew"
  end

  def test_live_wide_digits_match_the_fixed_ones_on_hardware
    assert_live_matches_fixed({})
  end

  def test_live_wide_digits_match_the_fixed_ones_on_a_tear_free_screen
    assert_live_matches_fixed({ tear_free: true })
  end

  # One column wider than a byte costs the glyph table's three extra bytes a row, not a copy of
  # every digit's pixels as instructions.
  def test_a_font_one_column_wider_than_a_byte_costs_about_the_same
    live = lambda do |glyphs|
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        font :figures, glyphs: glyphs
        var :score, 1987
        game_loop { draw_number :score, 40, 20, :white, digits: 4, font: :figures }
      end
      b.finalize_program
      GBA.new.lower(b.program).bytesize
    end

    narrow = live.call(padded_figures(3))
    wide = live.call(padded_figures(4))

    assert_operator wide - narrow, :<, 512, "a nine-wide font emitted #{wide} bytes against #{narrow} for eight"
  end
end
