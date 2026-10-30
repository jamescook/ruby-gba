# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_fade"

# Fading the whole screen on the Advance's cartridge, read back in the emulator: the same
# steps the game takes on every run, in test/all/vblank/builder/test_fade.rb.
class TestFadeCartridge < Minitest::Test
  include FadeGames

  private def rom_for(toward, amount)
    ROM.assemble(GBA.new.lower(faded(toward, amount)), title: "FADE", code: "BFAD", maker: "01")
  end

  # ...and the console says the same, for the same picture through the ROM.
  def test_the_console_shows_the_same_half_fade
    rom = assemble_rom(faded(:black, 50), name: "HALF")
    v = assert_emulator_loads_rom(rom, frames: 6)

    assert_equal [16, 0, 0], channels(v.pixel_gba(120, 80)), "red, half faded to black"
    assert_equal [0, 0, 15], channels(v.pixel_gba(10, 10)), "blue, half faded to black"
  end

  # A fade blends every layer, so it covers a tiled screen's tiles too (see tiled_fade).
  def test_a_fade_works_on_a_tiled_screen_too
    lit = ROM.assemble(GBA.new.lower(tiled_fade(0)), title: "FADET", code: "BFDT", maker: "01")
    dark = ROM.assemble(GBA.new.lower(tiled_fade(100)), title: "FADET", code: "BFDT", maker: "01")

    assert assert_emulator_loads_rom(lit, frames: 6).red?(60, 60), "the tiles are there to begin with"
    assert assert_emulator_loads_rom(dark, frames: 6).black?(60, 60),
           "and the fade covers them — every layer, not just the bitmap one"
  end

  # ...and the console says the same, step for step. This table is red's; green and blue
  # round the other way on the console, and the whole picture is held to it in
  # test_the_display_fade_matches_the_console_at_every_level_both_ways.
  def test_the_console_fades_a_channel_by_the_same_steps
    EVERY_LEVEL.each_with_index do |percent, step|
      rom = assemble_rom(a_red_wall_faded(percent), name: "FSTEP")
      console = assert_emulator_loads_rom(rom, frames: 6).pixel_gba(8, 8)

      assert_equal RED_FADED_TO_BLACK[step], console & 0x1F,
                   "red #{percent}% of the way to black, which is #{step} sixteenths"
    end
  end

  # --- on the console ---

  def test_the_fade_really_fades_on_the_console
    assert assert_emulator_loads_rom(rom_for(:black, 0), frames: 4).red?(120, 80),
           "with no fade the console shows the picture as drawn"
    assert assert_emulator_loads_rom(rom_for(:black, 100), frames: 4).black?(10, 10),
           "a full fade to black covers the screen"
    assert assert_emulator_loads_rom(rom_for(:white, 100), frames: 4).white?(10, 10),
           "and a full fade to white does too"
  end

  # Mid-fade the console lands exactly where the interpreter does, on a bitmap screen too.
  def test_a_half_fade_on_the_console_matches_the_interpreter
    console = assert_emulator_loads_rom(rom_for(:black, 50), frames: 4).pixel_gba(10, 10)
    interpreted = game_player.run(faded(:black, 50)).screen.pixel(10, 10)

    assert_equal interpreted, console
    refute_equal BLACK, console, "half way is not all the way"
    refute_equal BLUE, console, "and it is not nothing either"
  end

  # The colours are written into the console's colour table rather than blended by the
  # display, so there is no emulator rounding to allow for: every step is exact.
  def test_the_console_fades_a_fraction_in_the_same_thirty_two_steps
    EVERY_FINE_LEVEL.each_with_index do |percent, step|
      rom = assemble_rom(a_red_wall_faded(percent), name: "FFINE")
      console = assert_emulator_loads_rom(rom, frames: 6).pixel_gba(8, 8)

      assert_equal RED_FADED_FINELY[step], console & 0x1F, "red #{percent}% of the way to black"
    end
  end
end
