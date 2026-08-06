# frozen_string_literal: true

require "test_helper"

# draw_number on the tear-free (double-buffered, indexed) screen. There a live digit
# renders data-driven — one shared loop walks the embedded glyph table and splices a
# palette index into each pixel's byte — where a fixed number goes through the
# trusted per-pixel buffered text path. The two must land the same pixels: if the
# loop got the odd/even-column byte splice wrong, the live digits would come out
# garbled next to the fixed ones. Verified on real hardware.
class TestDrawNumberBuffered < Minitest::Test

  W = Builder::Text::GLYPH_WIDTH # 6px per default-font column

  # A buffered game that draws the same number two ways: once live (from a variable,
  # so the data-driven loop renders it) and once fixed (folded to glyphs at build
  # time, the per-pixel path). An odd origin (x = 41) deliberately exercises both the
  # even and odd column byte-splice on the indexed screen.
  def two_ways_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      var :score, 42
      game_loop do
        wait_vblank
        clear_screen :blue
        draw_number :score, 41, 20, :white, digits: 4 # live  -> data-driven buffered loop
        draw_number 42,     41, 40, :white, digits: 4 # fixed -> per-pixel buffered text
      end
    end
    b.emit_pending_functions
    b.program
  end

  def test_live_buffered_digits_match_the_fixed_ones_on_hardware
    rom = ROM.assemble(GBA.new.lower(two_ways_program), title: "BNUM", code: "BBNM", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 4)

    # Compare the two 4-digit fields pixel for pixel: the live band (y=20) must equal
    # the fixed band (y=40) everywhere, lit glyphs and blue gaps alike.
    (0...(4 * W)).each do |dx|
      (0...7).each do |dy|
        assert_equal v.pixel_gba(41 + dx, 40 + dy), v.pixel_gba(41 + dx, 20 + dy),
                     "buffered live vs fixed digit differ at column #{dx}, row #{dy}"
      end
    end
  end

  # A direct sanity check that the digits actually drew (not two identical blank
  # fields): somewhere in the live "42" a white pixel lands on the blue background.
  def test_the_buffered_digits_actually_render
    rom = ROM.assemble(GBA.new.lower(two_ways_program), title: "BNUM", code: "BBNM", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 4)

    drew = (0...(4 * W)).any? { |dx| (0...7).any? { |dy| v.white?(41 + dx, 20 + dy) } }
    assert drew, "the live buffered number should paint white digits on the blue field"
  end
end
