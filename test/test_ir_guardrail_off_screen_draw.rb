# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/ruby_gba"

# The off-screen-draw guardrail: a draw whose whole footprint (known at build
# time) lands off the 240x160 screen gets a soft, plain-language warning — it
# stays a safe no-op, this just saves the "why is nothing showing" hunt. A
# partly-off draw is intentional (edge clipping) and stays silent; a draw placed
# at a run-time position can't be judged here and is left alone. These assert the
# behavior on the IR, per the check's contract.
class TestIRGuardrailOffScreenDraw < Minitest::Test
  include RubyGBA::IR::Build

  Guardrails = RubyGBA::IR::Guardrails

  W = RubyGBA::IR::Screen::WIDTH  # 240
  H = RubyGBA::IR::Screen::HEIGHT # 160

  # The off-screen-draw warnings the checker raises for a program.
  def off_screen_warnings(prog)
    Guardrails::Validator.new.run(prog, autofix: false).findings
                         .select { |f| f.check == :off_screen_draw }
  end

  # ---- rectangles: each edge, and the on-screen / partial cases -------------

  def test_a_rectangle_off_the_right_edge_warns
    warnings = off_screen_warnings(program(fill_rect(W, 40, 10, 10, :red)))
    assert_equal 1, warnings.size
    assert_match(/off the #{W}x#{H} screen/, warnings.first.message)
  end

  def test_a_rectangle_off_the_left_edge_warns
    # x = -10, w = 10 -> right edge at 0, so the whole rect is left of the screen.
    assert_equal 1, off_screen_warnings(program(fill_rect(-10, 40, 10, 10, :red))).size
  end

  def test_a_rectangle_off_the_top_edge_warns
    assert_equal 1, off_screen_warnings(program(fill_rect(40, -10, 10, 10, :red))).size
  end

  def test_a_rectangle_off_the_bottom_edge_warns
    assert_equal 1, off_screen_warnings(program(fill_rect(40, H, 10, 10, :red))).size
  end

  def test_an_on_screen_rectangle_is_silent
    assert_empty off_screen_warnings(program(fill_rect(40, 40, 10, 10, :red)))
  end

  def test_a_partly_off_screen_rectangle_is_silent
    # Straddles the right edge — that's intentional (safe clipping), so no warning.
    assert_empty off_screen_warnings(program(fill_rect(W - 5, 40, 20, 10, :red)))
  end

  # ---- every positioned draw op the check understands -----------------------

  def test_an_off_screen_pixel_warns
    assert_equal 1, off_screen_warnings(program(pixel(W + 5, 40, :red))).size
  end

  def test_an_off_screen_dma_fill_warns
    assert_equal 1, off_screen_warnings(program(dma_fill_rect(40, H + 4, 8, 8, :blue))).size
  end

  def test_an_off_screen_draw_rect_at_with_constant_position_warns
    assert_equal 1, off_screen_warnings(program(draw_rect_at(-40, 40, 8, 8, :green))).size
  end

  def test_off_screen_text_warns_and_names_the_string
    warnings = off_screen_warnings(program(draw_text("HI", W + 1, 40, :white)))
    assert_equal 1, warnings.size
    assert_match(/"HI"/, warnings.first.message)
  end

  def test_an_off_screen_blit_warns
    prog = program(
      bitmap(:ship, width: 8, height: 8, pixels: ("\x00" * 128).b),
      blit(:ship, -20, 40),
    )
    assert_equal 1, off_screen_warnings(prog).size
  end

  def test_an_on_screen_blit_is_silent
    prog = program(
      bitmap(:ship, width: 8, height: 8, pixels: ("\x00" * 128).b),
      blit(:ship, 100, 40),
    )
    assert_empty off_screen_warnings(prog)
  end

  # ---- run-time positions can't be judged here ------------------------------

  def test_a_draw_at_a_variable_position_is_left_alone
    # x is a variable, decided at run time (and clipped safely then) — the build
    # can't know where it lands, so no warning.
    assert_empty off_screen_warnings(program(draw_rect_at(var_ref(:x), 40, 8, 8, :green)))
  end

  # ---- it's advisory, and it finds draws nested in the program --------------

  def test_the_warning_is_advisory_not_an_error
    report = Guardrails::Validator.new.run(program(display(:bitmap), fill_rect(W, 40, 8, 8, :red), halt),
                                           autofix: false)
    assert report.ok?, "an off-screen draw doesn't break the build — it's a warning"
    assert(report.warnings.any? { |w| w.check == :off_screen_draw })
  end

  def test_a_draw_nested_in_a_loop_is_still_checked
    prog = program(display(:bitmap), loop_(wait_vblank, fill_rect(W, 40, 8, 8, :red)))
    assert_equal 1, off_screen_warnings(prog).size, "the walk reaches draws inside control flow"
  end

  # ---- the warning reaches RubyGBA.build's err stream -----------------------

  def test_build_surfaces_the_off_screen_warning
    err = StringIO.new
    RubyGBA.build("GUARD", code: "BGRD", maker: "01", out: StringIO.new, err: err) do
      screen :bitmap
      fill_rect 250, 40, 10, 10, :red # off the right edge — nothing will show
      halt
    end

    assert_match(/off the #{W}x#{H} screen/, err.string)
  end
end
