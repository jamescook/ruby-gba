# frozen_string_literal: true

require "test_helper"
require "stringio"
require "console/gba/examples/test_pong_title"

# Pong's title screen on the Advance's cartridge (examples/pong.rb), read in the emulator. What
# the title shows and does is in test/console/gba/examples/test_pong_title.rb.
class TestPongTitleCartridge < Minitest::Test
  include PongTitleRows

  # --- on the console ---

  def test_the_title_menu_composites_on_real_hardware
    require_emulator!
    rom = Pong.build_rom(out: StringIO.new, err: StringIO.new)

    still = assert_emulator_loads_rom(rom, frames: 6)

    assert still.white?(column - 11, ROW_START + 1),
           "the cursor sits beside START, drawn by the sprite hardware over the zooming backdrop"

    moved = assert_emulator_loads_rom(rom, frames: 8, keys: VBlank::Console::Hardware::KEY_DOWN)

    assert moved.white?(column - 11, ROW_MUSIC + 1), "and walks to the music row"
  end

  # The one column MUSIC: OFF reaches and MUSIC: ON does not — the last "F". A GLYPH
  # there while the music is on means both sets of words are on screen at once, printed
  # over each other, which is what a row showing every one of its labels looks like.
  #
  # "Is it black" is the wrong question of this screen: the title's backdrop is a
  # checkerboard, so that column is a dark tile rather than nothing. The question is
  # whether a LETTER is drawn on it, and a letter is one of the row's two colours.
  private def beyond_the_shorter_words
    [column + (MUSIC_ON.length * Fonts.get(:default).cell_w), ROW_MUSIC]
  end

  private def lettered?(verifier, at)
    verifier.pixel_is?(*at, :white) || verifier.pixel_is?(*at, :gray)
  end

  def test_the_console_shows_one_set_of_words_and_not_both
    require_emulator!
    rom = Pong.build_rom(out: StringIO.new, err: StringIO.new)

    on = assert_emulator_loads_rom(rom, frames: 6)

    refute lettered?(on, beyond_the_shorter_words),
           "MUSIC: ON is up, so no letter reaches the column only MUSIC: OFF fills"

    # Down onto the music row, then A to turn it off — and now that column IS lettered.
    walk = lambda do |frame|
      next VBlank::Console::Hardware::KEY_DOWN if frame < 3
      next 0 if frame < 6

      VBlank::Console::Hardware::KEY_A
    end
    off = assert_emulator_loads_rom(rom, frames: 12, keys: walk)

    assert lettered?(off, beyond_the_shorter_words), "and MUSIC: OFF reaches it"
  end
end
