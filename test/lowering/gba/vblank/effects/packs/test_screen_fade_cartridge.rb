# frozen_string_literal: true

require "test_helper"
require "fade_watch"
require "all/vblank/effects/packs/test_screen_fade"

# The screen fade on the Advance's own cartridge — `fade_out`, `fade_in` and `flash_screen` read
# off its screen in the emulator, frame by frame where a frame matters. What every run shows is in
# test/all/vblank/effects/packs/test_screen_fade.rb, which keeps the games both files play in
# ScreenFadeGames.
class TestScreenFadeCartridge < Minitest::Test
  include FadeWatch
  include ScreenFadeGames

  # --- and on the console ---

  # The lowering, confirmed on real hardware: the same drawing, at the same spot, reading
  # one colour part way through a fade and its own colour again once the fade lifts.
  def test_a_fade_darkens_and_lifts_on_the_console
    prog = program do
      screen :bitmap
      frame = var :frame, 0
      game_loop do
        clear_screen :red
        frame.add! 1
        (frame == 2).then { fade_out :black, frames: 4 }
        (frame == 20).then { fade_in frames: 4 }
      end
    end
    rom = VBlank::Cartridge::ROM.assemble(GBA.new.lower(prog), title: "FADE", code: "BFAD", maker: "01")

    assert assert_emulator_loads_rom(rom, frames: 12).black?(120, 80),
           "the console really does black the picture out"
    assert assert_emulator_loads_rom(rom, frames: 30).red?(120, 80),
           "and really does put it back"
  end

  # A bare flash after a slow fade, on the console: the picture is back a few frames after
  # the flash, where the forty-frame speed of the fade before it would still be lit.
  def test_a_bare_flash_after_a_slow_fade_is_over_quickly_on_the_console
    v = assert_emulator_loads_rom(assemble_rom(after_a_slow_fade { flash_screen :white }, name: "BAREFL"),
                                  frames: 104)
    refute v.red?(120, 80), "the flash has to show at all"
    v.step(12)
    assert v.red?(120, 80), "and a bare flash is over in six frames, got #{v.pixel_gba(120, 80)}"
  end

  # A coloured flash on the TEAR-FREE screen, which is where a real game meets this: that
  # screen draws every pixel through a colour table, so the flash goes through the
  # framework's own blend rather than the display's. Breakout is a tear-free game and its
  # damage flash is exactly this.
  def test_a_coloured_flash_shows_and_lifts_on_the_console
    prog = program do
      screen :bitmap, tear_free: true
      frame = var :frame, 0
      game_loop do
        clear_screen :green
        frame.add! 1
        (frame == 2).then { flash_screen :red, frames: 6 }
      end
    end
    rom = VBlank::Cartridge::ROM.assemble(GBA.new.lower(prog), title: "FLASH", code: "BFLS", maker: "01")

    assert assert_emulator_loads_rom(rom, frames: 4).red?(120, 80),
           "the console really does sting the picture red"
    assert assert_emulator_loads_rom(rom, frames: 30).green?(120, 80),
           "and really does leave it as it was drawn"
  end

  # The two kinds of screen a game opening on an effect is asked about.
  OPENING_SCREENS = %i[bitmap tiled].freeze

  # AN EFFECT SET BEFORE THE GAME LOOP IS IN FORCE ON THE FIRST FRAME SHOWN (see opening_on).
  def test_the_console_never_shows_the_picture_before_the_effect
    OPENINGS.each do |name, effect|
      OPENING_SCREENS.each do |kind|
        v = assert_emulator_loads_rom(assemble_rom(opening_on(kind, &effect), name: "OPEN#{kind.to_s[0]}"), frames: 1)
        shown = Array.new(6) do
          pixel = v.pixel_gba(120, 80)
          v.step
          pixel
        end
        frames = shown.map { |p| format("%04x", p) }.join(" ")

        refute_includes shown, RED, "a #{kind} game opening on a #{name} showed the picture without it (#{frames})"
        assert_includes shown, BLACK, "a #{kind} game opening on a #{name} never showed it at full (#{frames})"
      end
    end
  end

  # --- a long fade steps every frame ---

  def test_the_console_steps_a_long_fade_every_frame
    v = assert_emulator_loads_rom(assemble_rom(long_fade(:tiled), name: "LONGF"), frames: 1)
    shown = Array.new(90) do
      pixel = v.pixel_gba(120, 80)
      v.step
      pixel
    end
    interpreted = ramp(long_fade(:tiled), 90)

    assert_equal interpreted.chunk_while { |a, b| a == b }.map(&:first),
                 shown.chunk_while { |a, b| a == b }.map(&:first).drop_while { |px| px != RED },
                 "the console walks through the same pictures in the same order"
  end
end
