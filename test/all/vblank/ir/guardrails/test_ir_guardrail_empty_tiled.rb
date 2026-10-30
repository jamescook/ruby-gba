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
# The proof of that on the emulated console, before any guardrail is involved, is in
# test/lowering/gba/vblank/ir/guardrails/test_ir_guardrail_empty_tiled_cartridge.rb.
class TestIRGuardrailEmptyTiled < Minitest::Test
  include VBlank::IR::Build

  # --- The guardrail that catches it before the ROM is built ---

  Guardrails = VBlank::IR::Guardrails

  private def validator
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
    builder.finalize_program

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
    assert_raises(VBlank::ROMError) do
      VBlank.build("BLANK", console: :gba, code: "BBLN", maker: "01", out: StringIO.new, err: err) do
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
