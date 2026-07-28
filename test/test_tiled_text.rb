# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Tiled-mode text & numbers: on a `screen :tiled` there's no framebuffer, so
# draw_text / draw_number render each glyph as a little hardware sprite the console
# composites over the game. The surface is the same as bitmap mode, with one rule —
# declare it once, above the game loop, because (like a sprite) it's redrawn for you
# every frame and a live number updates itself from its variable. These assert the
# observable result: the right glyph lands in the right place, the number tracks its
# variable, leading zeros blank out — on the interpreter oracle and on real hardware.
class TestTiledText < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color
  Fonts = RubyGBA::Fonts

  WHITE = Color.resolve(:white)

  # Build a tiled program that declares some HUD text once, then loops one frame and
  # halts (long enough for the sprites to be composited).
  def hud_program(&declare)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      instance_eval(&declare)
      game_loop do
        wait_vblank
        halt
      end
    end
    b.emit_pending_functions
    b.program
  end

  # Assert the glyph for +char+ of the default font is painted in +color+ at origin
  # (gx, gy) on +screen+: every lit pixel of the glyph is that color. Reading the font
  # itself keeps this independent of the exact glyph shape.
  def assert_glyph(screen, char, gx, gy, color)
    lit = []
    Fonts.get(:default).each_pixel(char) { |dx, dy| lit << [dx, dy] }
    refute_empty lit, "the font should have a glyph for #{char.inspect}"
    lit.each do |dx, dy|
      assert_equal color, screen.pixel(gx + dx, gy + dy),
                   "glyph #{char.inspect} pixel (#{dx},#{dy}) should be painted at (#{gx + dx},#{gy + dy})"
    end
  end

  def test_draw_text_paints_its_glyphs_as_sprites
    prog = hud_program { draw_text "AB", 100, 20, :white }
    s = Ruby.new.run(prog, max_steps: 500).screen
    assert_glyph(s, "A", 100, 20, WHITE)
    assert_glyph(s, "B", 100 + Fonts.get(:default).cell_w, 20, WHITE) # one cell over
  end

  def test_a_live_number_shows_its_variables_value
    prog = hud_program do
      var :score, 7
      draw_number :score, 100, 20, :white, digits: 1
    end
    s = Ruby.new.run(prog, max_steps: 500).screen
    assert_glyph(s, "7", 100, 20, WHITE)
  end

  def test_a_two_digit_number_places_both_digits
    prog = hud_program do
      var :score, 42
      draw_number :score, 100, 20, :white, digits: 2
    end
    s = Ruby.new.run(prog, max_steps: 500).screen
    cell = Fonts.get(:default).cell_w
    assert_glyph(s, "4", 100, 20, WHITE)
    assert_glyph(s, "2", 100 + cell, 20, WHITE)
  end

  def test_leading_zeros_are_blank_not_drawn
    prog = hud_program do
      var :score, 5
      draw_number :score, 100, 20, :white, digits: 3 # shows "  5"
    end
    s = Ruby.new.run(prog, max_steps: 500).screen
    cell = Fonts.get(:default).cell_w
    # The ones column (third) shows 5; the two leading columns are blank — no white
    # pixel anywhere in their 8x8 boxes.
    assert_glyph(s, "5", 100 + 2 * cell, 20, WHITE)
    # A blank column draws nothing in its own advance width. (The 8x8 glyph sprites
    # overlap the narrower advance, so we check only this column's own `cell` pixels —
    # past that we'd be reading the neighbouring digit's sprite.)
    [0, 1].each do |col|
      box = (0...8).flat_map { |dy| (0...cell).map { |dx| s.pixel(100 + col * cell + dx, 20 + dy) } }
      refute_includes box, WHITE, "leading column #{col} should be blank"
    end
  end

  def test_a_live_number_updates_itself_each_frame
    # No per-frame draw call: the number is declared once and its digit sprite reads
    # the variable every frame. Increment past 9 and halt; the last composited frame
    # must show the current value.
    b = Builder.new
    b.instance_eval do
      screen :tiled
      var :score, 0
      draw_number :score, 100, 20, :white, digits: 1
      game_loop do
        wait_vblank            # composites the score's current digit
        add :score, 1
        if_eq(:score, 6) { halt } # after this frame's present showed 6-1... see below
      end
    end
    b.emit_pending_functions
    s = Ruby.new.run(b.program, max_steps: 2_000).screen
    # Frame N presents score, then adds 1; it halts the frame it presents 5 then makes 6.
    assert_glyph(s, "5", 100, 20, WHITE)
  end

  # --- friendly guardrails ---

  def test_declaring_tiled_text_inside_the_loop_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :tiled
        game_loop do
          wait_vblank
          draw_text "HI", 10, 10, :white # wrong: inside the loop
        end
      end
    end
    assert_match(/once, above your game_loop/, err.message)
  end

  def test_a_live_number_needs_a_variable_not_an_expression
    err = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :tiled
        hp = var :hp, 10
        draw_number hp - 1, 10, 10, :white # an expression can't be tracked per frame
      end
    end
    assert_match(/follows a variable/, err.message)
  end

  # --- hardware: the same HUD renders on the console ---

  def test_the_hud_renders_on_the_console
    prog = hud_program do
      var :score, 42
      draw_number :score, 100, 20, :white, digits: 2
    end
    rom = ROM.assemble(GBA.new.lower(prog), title: "HUD", code: "BHUD", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 3)
    cell = Fonts.get(:default).cell_w
    # A lit pixel of "4" and of "2" should be white on the real framebuffer.
    Fonts.get(:default).each_pixel("4") do |dx, dy|
      assert v.white?(100 + dx, 20 + dy), "‘4’ pixel (#{dx},#{dy}) on hardware"
      break
    end
    Fonts.get(:default).each_pixel("2") do |dx, dy|
      assert v.white?(100 + cell + dx, 20 + dy), "‘2’ pixel (#{dx},#{dy}) on hardware"
      break
    end
  end
end
