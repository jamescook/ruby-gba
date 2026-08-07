# frozen_string_literal: true

require "test_helper"

require_relative "helper"

# A pixel on the direct-color screen comes in three shapes, and they are not one price.
#
# The screen holds a color in two bytes and writes one wherever it likes, so there is
# none of the tear-free screen's pairing to explain (that is the neighbouring file).
# What differs here is how much the console has to work out BEFORE each write:
#
#   a lone `pixel`        works out a whole address and fetches its color, for one write
#   a pixel of a RUN      the color is already held and the address settled while
#                         building — `fill_rect`'s write-out, and a font glyph's lit
#                         pixels
#   a SOFTWARE SPRITE's   the position is worked out as the program runs, so every pixel
#   lit pixel             is tested against the screen edges on its own before it goes in
#
# All three were charged the lone pixel's price. Measured on the console, a pixel of a run
# is about a quarter cheaper than that, and a sprite's is over twice dearer — so ordinary
# filling and text read dearer than they are, and sprites, which is what a bitmap game is
# mostly made of, read at under half.
#
# These assert the SHAPE of the answer (which of two things costs more, and why) rather
# than numbers that move when the weights are re-measured.
class TestDirectPixels < CostModelTest
  def direct(&block)
    program do
      screen :bitmap
      instance_eval(&block)
    end
  end

  # Art of the given size with `lit` pixels lit on each of its top `rows` rows, the rest
  # see-through. Written out so a test can say exactly how many pixels are lit and on how
  # many rows — those two numbers are what a software sprite costs.
  #
  # `lit` must leave at least one see-through pixel. Art with none is not transparent at
  # all and streams onto the screen instead, which is a different price entirely (its own
  # test at the bottom of this file).
  def art(width:, height:, lit:, rows: height)
    Array.new(height) { |row| (row < rows ? "#" * lit : "").ljust(width, ".") }.join("\n")
  end

  # `color` matters as well as the shape: drawing a pixel at a time writes the color into
  # every store, and only some colors fit inside it. Red does; white does not.
  def sprite_program(width:, height:, lit:, rows: height, color: :red)
    picture = art(width: width, height: height, lit: lit, rows: rows)
    direct do
      image(:art, "#" => color, "." => :transparent) { picture }
      x = var :sx, 40
      y = var :sy, 20
      game_loop { blit :art, x, y }
    end
  end

  # --- a pixel of a run ---

  # The bead's first question. A rectangle of a fixed size is written straight out, and
  # the whole rectangle is one run: the color is loaded once and every address is settled
  # while building. Charging it the lone pixel's price — which pays for working out an
  # address and fetching a color, per pixel — over-charged it by about a quarter.
  def test_a_fill_is_priced_by_a_pixel_of_a_run_not_a_lone_one
    filled = direct { game_loop { fill_rect 0, 0, 40, 20, :red } }
    lone = direct { game_loop { pixel 10, 10, :red } }

    near plot_rect(40, 20), Cost.new.steady_cost(filled)
    assert_operator Cost.new.steady_cost(filled), :<, 40 * 20 * Cost.new.steady_cost(lone),
                    "a pixel of a run is cheaper than a lone one, so a fill of them must be too"
  end

  # Text is the same shape: the color is held for the whole line and each lit pixel is one
  # store at an address settled while building. So one weight covers both, and a line of
  # text costs its own lit pixels at exactly what a fill's pixels cost.
  def test_text_and_a_fill_price_a_pixel_the_same
    lit = RubyGBA::Fonts.get(:default).text_pixels("SCORE")
    text = direct { game_loop { draw_text "SCORE", 0, 80, :white } }

    near text_cost("SCORE"), Cost.new.steady_cost(text)
    near Cost.new.steady_cost(direct { game_loop { fill_rect 0, 0, lit, 1, :red } }),
         Cost.new.steady_cost(text)
  end

  # The other half of the same question: a pixel drawn ON ITS OWN really does pay to work
  # out an address and fetch a color, so it keeps the dearer price. Splitting the weight
  # must not have made everything cheap.
  def test_a_lone_pixel_keeps_its_own_dearer_price
    lone = direct { game_loop { pixel 10, 10, :red } }
    one_of_a_run = direct { game_loop { fill_rect 0, 0, 2, 1, :red } }

    near WEIGHTS[:plot_pixel], Cost.new.steady_cost(lone)
    assert_operator Cost.new.steady_cost(lone), :>, Cost.new.steady_cost(one_of_a_run) / 2,
                    "a lone pixel costs more than one pixel of a run"
  end

  # --- a software sprite ---

  # An image with a see-through color is drawn a pixel at a time so the background shows
  # between them, at a position the game works out — so every pixel carries its own test
  # against the screen edges. Measured, that is over twice a pixel of a fixed-size fill,
  # and it used to be charged less than half of what it is.
  def test_a_sprite_pixel_costs_more_than_a_pixel_of_a_fill
    sprite = sprite_program(width: 16, height: 8, lit: 14)
    fill = direct { game_loop { fill_rect 0, 0, 14, 8, :red } }

    near blit_art(14 * 8, 8), Cost.new.steady_cost(sprite)
    assert_operator Cost.new.steady_cost(sprite), :>, 2 * Cost.new.steady_cost(fill),
                    "a sprite's pixel is tested against the screen edges; a fill's is not"
  end

  # The saving grace, and the reason the count has to be taken from the art rather than
  # the size: a see-through pixel is never drawn at all. A small figure on a cut-out
  # background costs its figure, not its bounding box — charging the box would price
  # every sprite as a solid rectangle at the dearest per-pixel rate there is.
  def test_a_sprite_pays_for_its_lit_pixels_not_its_whole_box
    dense = sprite_program(width: 16, height: 8, lit: 14)
    sparse = sprite_program(width: 16, height: 8, lit: 4)

    near blit_art(4 * 8, 8), Cost.new.steady_cost(sparse)
    # The two images are the same size, so a price read off the size would make these
    # equal. Every bit of the difference is the pixels that are actually lit.
    near (14 - 4) * 8 * WEIGHTS[:blit_pixel],
         Cost.new.steady_cost(dense) - Cost.new.steady_cost(sparse)
  end

  # Two sprites of exactly the same shape can cost different amounts on their COLORS
  # alone. Drawing a pixel at a time means writing the color into every store, and only
  # some colors fit inside that instruction — the rest need a step of their own first.
  # It is worth about a tenth of the picture, which is too much to shrug at, and the model
  # can simply count them because it has the art.
  def test_a_color_that_does_not_fit_the_instruction_costs_more_every_pixel
    plain = sprite_program(width: 16, height: 8, lit: 14, color: :red)
    wide = sprite_program(width: 16, height: 8, lit: 14, color: :white)

    near blit_art(14 * 8, 8), Cost.new.steady_cost(plain)
    near blit_art(14 * 8, 8, wide: 14 * 8), Cost.new.steady_cost(wide)
    assert_operator Cost.new.steady_cost(wide), :>, Cost.new.steady_cost(plain),
                    "white has to be built before it can be written; red rides along"
  end

  # A row with nothing lit in it is skipped whole — not one test, not one address. So the
  # empty space under a short figure in a tall frame is free, which is what lets a sprite
  # sheet's uniform frame size cost nothing extra.
  def test_an_empty_row_of_a_sprite_costs_nothing
    short = sprite_program(width: 16, height: 16, lit: 8, rows: 4)
    exact = sprite_program(width: 16, height: 4, lit: 8, rows: 4)

    near Cost.new.steady_cost(exact), Cost.new.steady_cost(short)
  end

  # An image with NO see-through color is not drawn this way at all: it streams onto the
  # screen in whole rows, which is the cheap path. The split has to survive, or every
  # opaque background tile would be priced as a sprite.
  #
  # What decides it is whether a see-through pixel is actually THERE, not whether the
  # image was declared with a see-through color — so art whose every pixel is lit streams
  # even though it names one. Both programs below say the same thing about their art, and
  # both are right to cost the same.
  def test_an_image_with_no_see_through_pixel_streams_instead
    picture = art(width: 16, height: 8, lit: 16)
    plain = direct do
      image(:tile, "#" => :red) { picture }
      x = var :tx, 40
      y = var :ty, 20
      game_loop { blit :tile, x, y }
    end
    named = direct do
      image(:tile, "#" => :red, "." => :transparent) { picture }
      x = var :tx, 40
      y = var :ty, 20
      game_loop { blit :tile, x, y }
    end

    near dma_rows(16, 8), Cost.new.steady_cost(plain)
    near dma_rows(16, 8), Cost.new.steady_cost(named)
    assert_operator Cost.new.steady_cost(plain), :<,
                    Cost.new.steady_cost(sprite_program(width: 16, height: 8, lit: 14)),
                    "streaming whole rows beats testing and writing each pixel"
  end
end
