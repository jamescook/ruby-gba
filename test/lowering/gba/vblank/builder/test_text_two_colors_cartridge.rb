# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_text_two_colors"

# A two-colour label on the Advance's cartridge: the colour changing in the emulator, and what
# the words cost in the ARM the lowering emits. What every run draws is in
# test/all/vblank/builder/test_text_two_colors.rb.
class TestTextTwoColorsCartridge < Minitest::Test
  include TextTwoColorsGames

  def test_the_colour_changes_on_real_hardware
    require_emulator!
    program = label(on: :tiled)
    rom = VBlank::Cartridge::ROM.assemble(GBA.new.lower(program), title: "TWOCOL", code: "BTWO", maker: "01")

    # A pixel the "H" lights: its left stem, two rows down.
    pixel = [X, Y + 2]

    dull = assert_emulator_loads_rom(rom, frames: 4)

    assert dull.pixel_is?(*pixel, :gray), "the label starts in the first colour"

    bright = assert_emulator_loads_rom(rom, frames: 6, keys: VBlank::Console::Hardware::KEY_A)

    assert bright.white?(*pixel), "and the console swaps it for the second when the test holds"
  end

  # ---- a bitmap screen paints the words once, whichever colour they are ----
  #
  # A painted pixel costs the same however its colour was decided, so a two-colour label on
  # a bitmap screen used to be written out the long way: every letter's pixels once in each
  # colour, one set always skipped. That is no slower, and it is twice the code — measured on
  # a difficulty screen of long proportional rows, it made one routine 110K and kept it out
  # of the console's quick memory. The words are now painted once, with the colour picked by
  # the test just before.

  # How many bytes the words themselves came to: the program with them, less the same
  # program with nothing to paint.
  private def words_cost(tear_free:, colors:)
    with = GBA.new.lower(bitmap_label(LONG, tear_free: tear_free, colors: colors)).bytesize
    without = GBA.new.lower(bitmap_label(" ", tear_free: tear_free, colors: colors)).bytesize
    with - without
  end

  # The test and the two colours cost a handful of instructions. The words are hundreds of
  # pixel writes. So a second colour must not come anywhere near a second copy of the words.
  A_HANDFUL = 16 * 4 # instructions, at four bytes each

  def test_a_two_colour_label_on_a_bitmap_screen_paints_its_words_once
    one = words_cost(tear_free: false, colors: [:gray])
    two = words_cost(tear_free: false, colors: %i[gray white])

    assert_operator one, :>, 1000, "the words really are most of the program"
    assert_operator two - one, :<=, A_HANDFUL,
                    "a second colour costs a handful of instructions (#{one} bytes for one, #{two} for two)"
  end

  def test_a_two_colour_label_on_the_tear_free_screen_paints_its_words_once
    one = words_cost(tear_free: true, colors: [:gray])
    two = words_cost(tear_free: true, colors: %i[gray white])

    assert_operator one, :>, 1000, "the words really are most of the program"
    assert_operator two - one, :<=, A_HANDFUL,
                    "a second colour costs a handful of instructions (#{one} bytes for one, #{two} for two)"
  end
end
