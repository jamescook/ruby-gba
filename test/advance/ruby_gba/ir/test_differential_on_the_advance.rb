# frozen_string_literal: true

require "test_helper"

require "differential"

# THE TESTS OF ruby_gba/ir/test_differential.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# The differential test: the same program on both backends, compared over the
# WHOLE screen rather than at a few chosen pixels.
#
# Every other cross-backend test in this suite picks its pixels — the ones whose
# values the author could predict. This one predicts nothing. It takes the
# reference interpreter's screen as the answer key and demands the console's match
# it exactly, all 38,400 pixels, so a bug in the lowering has nowhere to hide:
# something drawn a pixel off, a row that wrapped, a sprite that left a trail, a
# region left painted from last frame.
#
# See test/differential.rb for the helper and for why the console runs a couple of
# frames longer than the interpreter for the same picture. On a native run the second
# picture is the game as C's. How the console is lined up against the interpreter is the
# GBA lowering's alone, and is tested in ir/backends/gba/test_console_line_up.rb.
class TestDifferentialOnTheAdvance < Minitest::Test
  # Makes a test class of its own, to check what a mismatch reports. Making a class is a
  # change to the whole process, so on the main Ractor. See test_helper.
  runs_on_the_main_ractor!

  include Differential

  # An 8x8 solid tile — the size the sprite and tile hardware wants.

  # A full 32x32 checkerboard map — the whole grid the console gives a background.
  # test_a_small_scrolling_map_shows_the_backdrop_past_its_edge covers the other
  # case, where the author fills in less than that.
  FULL_MAP = (0...32).map { |r| (0...32).map { |c| (r + c).even? ? "#" : "." }.join }.freeze

  private def build(&block)
    b = RubyGBA::Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # --- bitmap mode: the direct-color framebuffer ---

  # Everything that draws to the framebuffer at once. Each op writes pixels a
  # different way (whole-screen DMA, rect fill, per-row image copy, glyphs, a
  # single word), so a mistake in any one of them shows up as a difference here.
  # It paints in more colours than a painted Game Boy Color screen holds, so it plays
  # on the Advance's runs alone.
  def test_the_bitmap_drawing_ops_paint_the_same_screen
    assert_backends_agree(build do
      screen :bitmap
      clear_screen :blue
      fill_rect 8, 8, 40, 24, Color.resolve(:red)
      fill_rect 200, 130, 32, 24, Color.resolve(:green)
      image(:strip, "#" => :white, "." => :transparent) { "#.#.#.#.\n.#.#.#.#\n########" }
      blit :strip, 100, 70
      draw_text "DIFF", 60, 100, Color.resolve(:yellow)
      pixel 239, 159, Color.resolve(:magenta)
      halt
    end)
  end

  # THE EFFECTS THAT CHANGE NOTHING THAT WAS DRAWN — a fade, a tint, the camera.
  #
  # These are the hardest thing for a comparison like this to see, and for a while it
  # could not: reading the interpreter's stored cells shows the picture underneath an
  # effect, which is not what either display is putting out. So the whole family is
  # walked over a picture with several colors in it, because a blend is per channel and
  # a single flat fill would agree by luck.
  def test_a_fade_blends_the_same_picture_on_both_backends
    [0, 25, 50, 75, 100].each do |amount|
      assert_backends_agree(build do
        screen :bitmap
        clear_screen :blue
        fill_rect 8, 8, 40, 24, Color.resolve(:red)
        fill_rect 100, 60, 40, 24, Color.resolve(:green)
        draw_text "FADE", 60, 120, Color.resolve(:yellow)
        fade :black, amount
        halt
      end, name: "FADE")
    end
  end

  # --- tiled mode: the console composites tiles and sprites itself ---

  # --- the comparison itself has to be able to fail ---

end
