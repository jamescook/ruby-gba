# frozen_string_literal: true

require "test_helper"

require "stringio"

# Shared scaffolding for the cost-model tests, which are split by the question each
# part of the model answers — pricing one op, rolling a frame up, shaping the tree,
# judging it, printing it (see lib/ruby_gba/ir/cost_model/).
#
# Costs are in scanlines (measured on hardware — see the timing probe), so the
# expected values are derived from the model's own weights rather than hard-coded:
# a rectangle filled/copied by DMA costs per row (setup + pixels), a whole-screen
# clear is one DMA, a glyph is a fixed plot cost. Tests assert with a small delta
# (floats) or, better, assert the SHAPE (a tall rect costs more than a wide one of
# equal area; an opaque blit is cheaper than a transparent one) which doesn't move
# when the calibration is re-measured.
module CostArith
  WEIGHTS = RubyGBA::IR::CostModel::DEFAULT_WEIGHTS

  def dma_rows(w, h) = (h * WEIGHTS[:dma_setup]) + (w * h * WEIGHTS[:dma_pixel])
  # fill_rect in direct color: every pixel written out, one store each. They are a RUN,
  # which is cheaper per pixel than a lone `pixel` (that has to work out a whole address
  # and fetch its color for the one write).
  def plot_rect(w, h) = w * h * WEIGHTS[:plot_run_pixel]
  # A software sprite: an image with a see-through color, drawn a pixel at a time at a
  # position the game works out. Only the lit pixels are drawn, on the rows that have one.
  # `wide` is how many of those lit pixels carry a color that needs a step of its own to
  # build (the color is written into every store, and only some fit inside it).
  def blit_art(lit_pixels, lit_rows, wide: 0)
    WEIGHTS[:blit_start] + (lit_rows * WEIGHTS[:blit_row]) +
      (lit_pixels * WEIGHTS[:blit_pixel]) + (wide * WEIGHTS[:blit_wide_color])
  end
  def dma_blob(pixels) = WEIGHTS[:dma_setup] + (pixels * WEIGHTS[:dma_pixel])
  # The same whole-screen clear on the TEAR-FREE screen. It holds a pixel as one byte
  # where the direct-color screen holds the color itself in two, so one transfer covers
  # twice as many pixels — the same picture for half the work.
  def tearfree_clear = WEIGHTS[:dma_setup] + (240 * 160 * WEIGHTS[:dma_pixel] / 2)
  # A rectangle of a fixed size on the tear-free screen: a block fill per row, plus the
  # transfer, plus what it costs before the first row.
  def tearfree_fill(w, h)
    WEIGHTS[:tearfree_rect_start] + (h * WEIGHTS[:dma_setup]) + (w * h * WEIGHTS[:tearfree_fill_pixel])
  end
  # A repeat: each pass runs the body AND pays for going round (the count, the test, the
  # jump back), which is real work and roughly three plain steps.
  def loop_cost(passes, body) = passes * (body + WEIGHTS[:loop_pass])
  # A glyph/text costs the pixels it lights, in the given font — a run of them, priced
  # like the pixels of a fill.
  def text_cost(text, font = :default) = RubyGBA::Fonts.get(font).text_pixels(text) * WEIGHTS[:plot_run_pixel]
  def digit_cost(font = :default)
    RubyGBA::Fonts.get(font).max_glyph_pixels(("0".."9").to_a) * WEIGHTS[:plot_run_pixel]
  end
  def near(expected, actual, msg = nil) = assert_in_delta(expected, actual, 1e-6, msg)
end

# The base every cost-model test case builds on: the weights helpers, the short
# names for the classes under test, and the one route these tests use to build a
# program (through the DSL, like the other DSL tests).
class CostModelTest < Minitest::Test
  include CostArith

  Cost = RubyGBA::IR::CostModel
  Build = RubyGBA::IR::Build
  Node = RubyGBA::IR::Node

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # Every leaf of a cost tree, flattened — for asking what got a line of its own.
  def leaves(nodes)
    nodes.flat_map { |node| node[:children].to_a.empty? ? [node] : leaves(node[:children]) }
  end

  # A game loop that clears the whole screen +n+ times a frame, single- or
  # double-buffered. Built straight from the IR so it can flip the buffered flag the
  # DSL doesn't expose yet.
  def loop_of_clears(n, buffered:)
    Build.program(
      Build.screen(:bitmap, buffered: buffered),
      Build.loop_(Build.wait_vblank, *Array.new(n) { Build.clear_screen(:black) }),
    )
  end

  # A game with six collision tests it hardly ever passes. Six 16x16 pairs walk 345
  # scanlines against a 228-line frame IF they all land at once, which is the ceiling,
  # not the every-frame cost — the walk covers the overlap rectangle, and two sprites
  # that miss walk nothing. Charging it every frame made shmup read 101% of budget while
  # its busiest measured frame was 54 scanlines.
  def near_misses
    program do
      screen :tiled
      image(:blk, "#" => :red) { (["#" * 16] * 16).join("\n") }
      hits = var :hits, 0
      a = sprite :blk, at: [10, 10]
      others = Array.new(6) { |i| sprite :blk, at: [16 * i, 120] }
      game_loop do
        others.each { |b| a.overlaps?(b).then { hits.add 1 } }
      end
    end
  end

  # A program that plays a sample each frame, so the software mixer runs — real
  # per-frame CPU the estimate has to account for.
  def sample_game(rate: 8192)
    program do
      screen :bitmap
      clip = sample :blip, pcm: [10, -10] * 100, rate: rate
      game_loop { clip.play }
    end
  end

  def silent_game
    program { screen :bitmap; game_loop { fill_rect 0, 0, 10, 10, :red } }
  end

  # The rendered report/estimate for a program, as a String.
  def rendered(prog, **kwargs)
    io = StringIO.new
    Cost.new.render(prog, out: io, **kwargs)
    io.string
  end

  def reported(prog, **kwargs)
    io = StringIO.new
    Cost.new.report(prog, out: io, **kwargs)
    io.string
  end
end
