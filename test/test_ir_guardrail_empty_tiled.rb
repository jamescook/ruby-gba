# frozen_string_literal: true

require "test_helper"

# Tiled mode with nothing loaded into it — the black-screen footgun this guardrail
# exists to catch.
#
# Picking `screen :tiled` turns on a tile layer, but a tile layer draws nothing of
# its own: it paints whatever pictures live in video memory, arranged by whatever
# map sits beside them. Declare no background and no sprite and both are still all
# zeroes, so every cell paints tile zero, tile zero is entirely color zero, and
# color zero is black. The console is running the game perfectly and showing
# nothing — no crash, no error, no hint.
#
# The first two tests PROVE that, on the emulated console, before any guardrail is
# involved. They build the ROM straight from the IR (not through RubyGBA.build), so
# they bypass the validation pass and keep proving the hardware behavior even once
# the guardrail stops such a program from being built.
class TestIRGuardrailEmptyTiled < Minitest::Test
  include RubyGBA::IR::Build

  SOLID8 = (["########"] * 8).join("\n")

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

    v = assert_gemba_loads_rom(rom, frames: 4)
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
    builder.emit_pending_functions
    rom = ROM.assemble(GBA.new.lower(builder.program), title: "DRAWN", code: "BDRW", maker: "01")

    v = assert_gemba_loads_rom(rom, frames: 4)
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
      image(:red_t, "#" => :red) { SOLID8 }
      tiles :set, "R" => :red_t
      background :field, tiles: :set, map: Array.new(32) { "R" * 32 }
      game_loop do
        wait_vblank
        halt
      end
    end
    builder.emit_pending_functions
    rom = ROM.assemble(GBA.new.lower(builder.program), title: "FILLED", code: "BFIL", maker: "01")

    v = assert_gemba_loads_rom(rom, frames: 4)
    PROBES.each do |x, y|
      assert v.red?(x, y),
             "(#{x}, #{y}) should be red — one background makes the same tiled screen paint, " \
             "got 0x#{format('%04X', v.pixel_gba(x, y))}"
    end
  end

  # --- The guardrail that catches it before the ROM is built ---

  Guardrails = RubyGBA::IR::Guardrails

  def validator
    Guardrails::Validator.new(checks: [Guardrails::Checks::EmptyTiledScreen.new])
  end

  # The realistic case, and the one where the advice can be specific: the program
  # draws the way a bitmap screen draws, so the fix is to pick that screen.
  def test_bitmap_drawing_on_a_tiled_screen_is_told_to_switch_modes
    report = validator.run(program(screen(:tiled), fill_rect(10, 10, 20, 20, :red), halt),
                           autofix: false)

    refute report.ok?
    message = report.errors.first.message
    assert_match(/fill_rect/, message, "it names the verb the game actually used")
    assert_match(/screen :bitmap/, message, "and gives the one-line fix")
    assert_match(/black/i, message, "and says what goes wrong")
  end

  # The bare case: nothing drawn at all, so there is no verb to name. Here the fix
  # is to add content, and the message has to show what content looks like.
  def test_a_tiled_screen_with_no_content_is_told_to_add_some
    report = validator.run(program(screen(:tiled), wait_vblank, halt), autofix: false)

    refute report.ok?
    message = report.errors.first.message
    assert_match(/background/, message, "it points at the two things a tiled screen can show")
    assert_match(/sprite/, message)
    assert_match(/black/i, message)
  end

  # No false positive: a tiled screen with a background has content, so it paints.
  def test_a_tiled_screen_with_a_background_is_left_alone
    prog = program(screen(:tiled),
                   background(:level, tiles: :set, map: ["AB"], tile_w: 8, tile_h: 8),
                   halt)
    report = validator.run(prog, autofix: false)
    assert report.ok?
    assert_empty report.findings
  end

  # No false positive: `draw_text` on a tiled screen becomes sprite glyphs, so a
  # text-only HUD really does show something. Built through the DSL because that
  # mapping is the builder's job.
  def test_a_tiled_screen_with_only_text_is_left_alone
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      draw_text "HELLO", 40, 40, :white
      game_loop { wait_vblank }
    end
    builder.emit_pending_functions

    report = validator.run(builder.program, autofix: false)
    assert report.ok?, "tiled text draws as sprite glyphs, so the screen is not blank"
  end

  # No false positive: a bitmap program is not this check's business at all.
  def test_a_bitmap_screen_is_left_alone
    report = validator.run(program(screen(:bitmap), fill_rect(10, 10, 20, 20, :red), halt),
                           autofix: false)
    assert report.ok?
    assert_empty report.findings
  end

  # A program that switches modes per scene is out of scope: a bitmap scene's
  # drawing is correct there, and judging each scene separately is a different
  # check. Staying quiet here is better than blaming a valid program.
  def test_a_program_with_both_screen_modes_is_left_alone
    prog = program(screen(:bitmap), fill_rect(10, 10, 20, 20, :red), screen(:tiled), halt)
    report = validator.run(prog, autofix: false)
    assert report.ok?
    assert_empty report.findings
  end

  # At build time this stops the build — a guaranteed black screen must not ship
  # silently — with the explanation on the err stream.
  def test_build_halts_on_a_tiled_screen_with_nothing_to_show
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("BLANK", code: "BBLN", maker: "01", out: StringIO.new, err: err) do
        screen :tiled
        game_loop do
          wait_vblank
          fill_rect 100, 70, 40, 20, :red
        end
      end
    end
    assert_match(/screen :bitmap/, err.string, "the explanation gives the one-line fix")
    assert_match(/black/i, err.string)
  end
end
