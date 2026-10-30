# frozen_string_literal: true

require "test_helper"

# Proof, on the Advance's cartridge in the emulator, that a tiled screen with nothing loaded
# into it is the black-screen footgun the empty-tiled guardrail exists to catch. The guardrail
# itself is tested in test/all/vblank/ir/guardrails/test_ir_guardrail_empty_tiled.rb.
#
# These build the ROM straight from the IR (not through VBlank.build), so they bypass the
# validation pass and keep proving the hardware behavior even once the guardrail stops such a
# program from being built.
class TestIRGuardrailEmptyTiledCartridge < Minitest::Test
  include VBlank::IR::Build

  # Points spread over the screen — corners, edges and center. A tile layer with no
  # data is uniformly blank, so sampling a spread (rather than one pixel) shows the
  # whole frame is dark, not just the spot we happened to look at.
  PROBES = [[4, 4], [120, 4], [235, 4], [4, 80], [120, 80], [235, 80],
            [4, 155], [120, 155], [235, 155]].freeze

  # --- Proof that the footgun is real ---

  # A complete, valid, well-formed program: it picks a mode, syncs to the frame, and
  # stops. Nothing about it is broken — it just never gives the tile layer anything
  # to paint. The console shows black.
  def test_a_tiled_screen_with_nothing_loaded_renders_black_on_the_console
    prog = program(screen(:tiled), wait_vblank, halt)
    rom = ROM.assemble(GBA.new.lower(prog), title: "EMPTY", code: "BEMT", maker: "01")

    v = assert_emulator_loads_rom(rom, frames: 4)
    PROBES.each do |x, y|
      assert v.black?(x, y),
             "(#{x}, #{y}) should be black — a tiled screen with no tiles shows nothing, " \
             "got 0x#{format('%04X', v.pixel_gba(x, y))}"
    end
  end

  # The version of this a person actually writes. This game is not empty — it has a
  # loop, it syncs to the frame, and it draws a red square every frame. But
  # `fill_rect` paints the bitmap framebuffer, and a tiled screen doesn't show the
  # framebuffer, so the drawing lands somewhere nothing is looking at. The build
  # says nothing and the console shows black.
  def test_a_tiled_screen_drawn_on_with_bitmap_verbs_renders_black_on_the_console
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      game_loop do
        wait_vblank
        fill_rect 100, 70, 40, 20, :red
      end
    end
    builder.finalize_program
    rom = ROM.assemble(GBA.new.lower(builder.program), title: "DRAWN", code: "BDRW", maker: "01")

    v = assert_emulator_loads_rom(rom, frames: 4)
    assert v.black?(120, 80),
           "the square the game draws every frame never appears on a tiled screen, " \
           "got 0x#{format('%04X', v.pixel_gba(120, 80))}"
    PROBES.each do |x, y|
      assert v.black?(x, y),
             "(#{x}, #{y}) should be black — a tiled screen shows no bitmap drawing, " \
             "got 0x#{format('%04X', v.pixel_gba(x, y))}"
    end
  end

  # The contrast that makes the proof mean something: the SAME screen mode, on the
  # same emulator, with one background declared, is not black. So the black frame
  # above is caused by the missing tile data — not by tiled mode being broken, and
  # not by the emulator defaulting everything to black.
  def test_the_same_tiled_screen_with_one_background_is_not_black
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:red_t, "#" => :red) { SOLID_TILE }
      tiles :set, "R" => :red_t
      background :field, tiles: :set, map: Array.new(32) { "R" * 32 }
      game_loop do
        wait_vblank
        halt
      end
    end
    builder.finalize_program
    rom = ROM.assemble(GBA.new.lower(builder.program), title: "FILLED", code: "BFIL", maker: "01")

    v = assert_emulator_loads_rom(rom, frames: 4)
    PROBES.each do |x, y|
      assert v.red?(x, y),
             "(#{x}, #{y}) should be red — one background makes the same tiled screen paint, " \
             "got 0x#{format('%04X', v.pixel_gba(x, y))}"
    end
  end
end
