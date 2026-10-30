# frozen_string_literal: true

require "test_helper"

# The tests of test_facing_sheet.rb whose games paint more colours into one 8×8 square of the
# screen than a Game Boy Color's square holds — a sheet of a colour per cell, drawn on a bitmap
# over black — so they play on the Advance's runs alone.
class TestFacingSheetOnTheAdvance < Minitest::Test
  include VBlank::Console::Hardware

  Image = VBlank::Graphics::Image

  # A distinct color per cell, keyed [col, row]. Rows are down / left / right / up; the
  # two columns are frame 0 and frame 1. Reading the sprite's pixel says both which way
  # it faces (the row) and which frame is up (the column).
  CELLS = {
    [0, 0] => [255, 0, 0],    [1, 0] => [0, 255, 0],     # down:  red,     green
    [0, 1] => [0, 0, 255],    [1, 1] => [255, 255, 255], # left:  blue,    white
    [0, 2] => [255, 255, 0],  [1, 2] => [0, 255, 255],   # right: yellow,  cyan
    [0, 3] => [255, 0, 255],  [1, 3] => [64, 64, 64],    # up:    magenta, dark gray
  }.freeze
  DIRS = %i[down left right up].freeze

  # An image adapter that hands back a directional sheet of +cols+ columns and 4 rows of
  # 8x8 cells, colored by CELLS. Same shape the real ImageMagick adapter exposes.
  class SheetAdapter
    def initialize(cols)
      @cols = cols
    end

    def dimensions(_path) = [@cols * 8, 4 * 8]

    def rgb_pixels(_path, width:, height:)
      bytes = (+"").b
      height.times do |y|
        width.times do |x|
          r, g, b = CELLS[[x / 8, y / 8]]
          bytes << r.chr << g.chr << b.chr
        end
      end
      bytes
    end

    def rgba_pixels(_path, **) = nil
  end

  private def with_adapter(cols, &block) = Image.with_adapter(SheetAdapter.new(cols), &block)

  # A hero at (40, 40) whose four-way art is imported from a +cols+-column sheet, facing
  # +face+, run +run+ frames then halted (so the screen is deterministic). An absolute
  # image path skips the on-disk lookup, so the fake sheet never has to exist.
  private def walker(mode:, face:, run:, cols: 2, rate: 2)
    builder = Builder.new
    with_adapter(cols) do
      builder.instance_eval do
        screen mode
        if mode == :tiled
          image(:field, "#" => :black) { SOLID_TILE }
          tiles :ground, "#" => :field
          background :bg, tiles: :ground, map: Array.new(20, "#" * 30)
        else
          clear_screen :black
        end
        opts = { tile: 8, dirs: DIRS }
        opts[:rate] = rate if cols > 1
        hero = sprite :hero, at: [40, 40], facing_from: "/walk.png", **opts
        hero.face face
        f = var :f, 0
        game_loop do
          wait_vblank
          f.add! 1
          (f >= run).then { halt }
        end
      end
      builder.finalize_program
    end
    builder.program
  end

  private def spot(program)
    game_player.run(program).screen.pixel(44, 44)
  end

  private def color(r, g, b) = Color.rgb8(r, g, b)

  def test_each_row_of_the_sheet_becomes_a_direction
    assert_equal color(255, 0, 0),   spot(walker(mode: :bitmap, face: :down,  run: 2)), "row 0 -> down"
    assert_equal color(0, 0, 255),   spot(walker(mode: :bitmap, face: :left,  run: 2)), "row 1 -> left"
    assert_equal color(255, 255, 0), spot(walker(mode: :bitmap, face: :right, run: 2)), "row 2 -> right"
    assert_equal color(255, 0, 255), spot(walker(mode: :bitmap, face: :up,    run: 2)), "row 3 -> up"
  end

  def test_the_columns_of_a_row_animate
    assert_equal color(255, 0, 0), spot(walker(mode: :bitmap, face: :down, run: 2)), "down, first frame"
    assert_equal color(0, 255, 0), spot(walker(mode: :bitmap, face: :down, run: 4)), "down, next frame"
  end

  # A one-column sheet is a still pose per direction — a plain facing: sprite, no rate.
  def test_a_one_column_sheet_is_a_still_pose_per_direction
    assert_equal color(255, 0, 0), spot(walker(mode: :bitmap, face: :down,  run: 3, cols: 1))
    assert_equal color(0, 0, 255), spot(walker(mode: :bitmap, face: :left,  run: 3, cols: 1))
  end
end
