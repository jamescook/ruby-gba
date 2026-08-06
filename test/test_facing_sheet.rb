# frozen_string_literal: true

require "test_helper"

# `sprite ..., facing_from: "sheet.png", tile:, dirs: [...]` imports a directional
# sprite sheet: each ROW of the sheet is a direction (in the order dirs: names, top to
# bottom) and the COLUMNS of that row are its frames. One column gives a still pose per
# direction (a plain facing: sprite); several columns give a per-direction animation.
# So a four-way character's art comes from one file, like its frames and tiles do.
#
# The sheet is sliced through a fake image adapter (canned pixels, no ImageMagick), but
# the slicing happens at BUILD time and bakes real images into the program — so the same
# imported art is checked on the interpreter oracle AND on real hardware (gemba).
class TestFacingSheet < Minitest::Test
  include RubyGBA::Constants

  Image = RubyGBA::Image

  SOLID8 = (["########"] * 8).join("\n")

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

  def with_adapter(cols)
    saved = Image.instance_variable_get(:@default_adapter)
    Image.instance_variable_set(:@default_adapter, SheetAdapter.new(cols))
    yield
  ensure
    Image.instance_variable_set(:@default_adapter, saved)
  end

  # A hero at (40, 40) whose four-way art is imported from a +cols+-column sheet, facing
  # +face+, run +run+ frames then halted (so the screen is deterministic). An absolute
  # image path skips the on-disk lookup, so the fake sheet never has to exist.
  def walker(mode:, face:, run:, cols: 2, rate: 2)
    builder = Builder.new
    with_adapter(cols) do
      builder.instance_eval do
        screen mode
        if mode == :tiled
          image(:field, "#" => :black) { SOLID8 }
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
          f.add 1
          (f >= run).then { halt }
        end
      end
      builder.emit_pending_functions
    end
    builder.program
  end

  def spot(program)
    Reference.new.run(program).screen.pixel(44, 44)
  end

  def color(r, g, b) = Color.rgb8(r, g, b)

  # --- the interpreter oracle: each row imported to the right direction; frames animate ---

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

  def test_a_hardware_sprite_imports_the_same_way
    assert_equal color(255, 0, 0),   spot(walker(mode: :tiled, face: :down,  run: 2)), "tiled: down"
    assert_equal color(255, 255, 0), spot(walker(mode: :tiled, face: :right, run: 2)), "tiled: right"
  end

  # --- real hardware: the imported sheet composites on the console ---

  def test_on_console_the_imported_sheet_composites
    rom = ROM.assemble(GBA.new.lower(walker(mode: :tiled, face: :right, run: 3)),
                       title: "FACESHT", code: "BFSH", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 3)
    assert v.pixel_is?(44, 44, color(255, 255, 0)),
           "facing right, the console should composite the imported right-facing frame (yellow), got #{v.pixel_gba(44, 44).to_s(16)}"
  end

  # --- friendly errors ---

  def sprite_error(cols, &block)
    b = Builder.new
    with_adapter(cols) { assert_raises(ArgumentError) { b.instance_eval(&block) } }
  end

  def test_dirs_must_match_the_number_of_rows
    err = sprite_error(2) do
      screen :bitmap
      sprite :h, at: [0, 0], facing_from: "/walk.png", tile: 8, dirs: %i[down left], rate: 2
    end
    assert_match(/one direction for each row/, err.message)
  end

  def test_facing_from_needs_dirs
    err = sprite_error(2) do
      screen :bitmap
      sprite :h, at: [0, 0], facing_from: "/walk.png", tile: 8, rate: 2
    end
    assert_match(/needs dirs:/, err.message)
  end

  def test_facing_from_and_facing_together_are_a_friendly_error
    err = sprite_error(2) do
      screen :bitmap
      sprite :h, at: [0, 0], facing_from: "/walk.png", tile: 8, dirs: DIRS,
                 facing: { left: :a, right: :b }, rate: 2
    end
    assert_match(/both facing: and facing_from:/, err.message)
  end
end
