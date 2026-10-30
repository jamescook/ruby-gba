# frozen_string_literal: true

require "test_helper"

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
#
# The tests that play the picture on the interpreter paint more colours into one 8×8 square of
# the screen than a Game Boy Color's square holds, so they are in
# test/console/gba/vblank/builder/test_buffered_blit_on_the_advance.rb. What the Advance's
# cartridge shows is read in the emulator in
# test/lowering/gba/vblank/builder/test_buffered_blit_cartridge.rb, which draws the picture
# kept here in BufferedBlitGames.
module BufferedBlitGames
  include SharedConstants # Color, which the picture below names from inside the module

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
end

class TestBufferedBlit < Minitest::Test
  include VBlank::IR::Build
  include BufferedBlitGames

  # --- what this cannot draw yet, said plainly -------------------------------------

  def test_an_odd_column_is_a_friendly_error
    err = assert_raises(VBlank::IR::Backends::GBA::LoweringError) do
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
    err = assert_raises(VBlank::IR::Backends::GBA::LoweringError) { assemble_rom(prog, name: "BVAR") }
    assert_match(/even/, err.message)
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
    err = assert_raises(VBlank::IR::Backends::GBA::LoweringError) { assemble_rom(prog, name: "BGHOST") }
    assert_match(/see-through/, err.message)
  end
end
