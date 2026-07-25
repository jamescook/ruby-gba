# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The glyph-reachability pass: which glyphs a program can actually be asked to draw,
# per font — the tree-shaking brain a data-driven font uses to embed only what's
# needed. Static text contributes its exact (folded) characters; draw_number
# contributes 0-9.
class TestGlyphUsage < Minitest::Test
  Builder = RubyGBA::Builder
  Usage = RubyGBA::IR::GlyphUsage
  Fonts = RubyGBA::Fonts

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  def teardown
    reg = Fonts.instance_variable_get(:@registry)
    (reg.keys - %i[default tiny]).each { |k| reg.delete(k) }
  end

  def test_static_text_contributes_its_exact_characters
    prog = program { screen(:bitmap); draw_text("HI", 0, 0, :white); halt }
    assert_equal({ default: %w[H I] }, Usage.reachable(prog))
  end

  def test_characters_are_folded_through_the_font
    # the default font is uppercase-only, so "hi" reaches the H and I glyphs
    prog = program { screen(:bitmap); draw_text("hi", 0, 0, :white); halt }
    assert_equal(%w[H I], Usage.reachable(prog)[:default])
  end

  def test_a_number_contributes_the_ten_digits
    prog = program { screen(:bitmap); var(:s, 0); draw_number(:s, 0, 0, :white); halt }
    assert_equal(("0".."9").to_a, Usage.reachable(prog)[:default])
  end

  def test_usage_is_grouped_by_font
    prog = program do
      screen :bitmap
      draw_text "AB", 0, 0, :white               # default
      draw_text "12", 0, 8, :white, font: :tiny  # tiny
      halt
    end
    reach = Usage.reachable(prog)
    assert_equal(%w[A B], reach[:default])
    assert_equal(%w[1 2], reach[:tiny])
  end

  def test_the_footprint_shows_tree_shaking
    # a 3-digit score in the big default font touches only the ten digit glyphs, far
    # fewer than the font's full set — the whole point of tree-shaking.
    prog = program { screen(:bitmap); var(:s, 0); draw_number(:s, 8, 8, :white, digits: 3); halt }
    fp = Usage.footprint(prog).find { |f| f[:font] == :default }
    assert_equal 10, fp[:drawn]
    assert_operator fp[:total], :>, 30, "the default font has far more glyphs than are drawn"
    assert_operator fp[:drawn], :<, fp[:total]
  end
end
