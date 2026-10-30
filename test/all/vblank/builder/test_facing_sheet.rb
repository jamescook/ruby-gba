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
# imported art is checked on every run here AND on real hardware (the emulator), in
# test/lowering/gba/vblank/builder/test_facing_sheet_cartridge.rb.
#
# The sheet and the games built from it, shared by both files.
module FacingSheetGames
  include SharedConstants

  Image = VBlank::Graphics::Image

  # A distinct color per cell, keyed [col, row]. Rows are down / left / right / up; the
  # two columns are frame 0 and frame 1. Reading the sprite's pixel says both which way
  # it faces (the row) and which frame is up (the column).
  #
  # Made shareable here, since a test plays in a Ractor and test_helper deep-freezes only the
  # constants a test class declares, not a module's.
  CELLS = Ractor.make_shareable({
    [0, 0] => [255, 0, 0],    [1, 0] => [0, 255, 0],     # down:  red,     green
    [0, 1] => [0, 0, 255],    [1, 1] => [255, 255, 255], # left:  blue,    white
    [0, 2] => [255, 255, 0],  [1, 2] => [0, 255, 255],   # right: yellow,  cyan
    [0, 3] => [255, 0, 255],  [1, 3] => [64, 64, 64],    # up:    magenta, dark gray
  })
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

  private def color(r, g, b) = Color.rgb8(r, g, b)

  # --- a four-way sprite from a sheet can be drawn with other colours ---
  #
  # Every picture the sheet is cut into is drawn from the list given, so another list swaps
  # them by place: the right-facing yellow is the list's third colour, drawn in the third of
  # the other list.
  private def a_recolored_walker
    builder = Builder.new
    with_adapter(1) do
      builder.instance_eval do
        screen :tiled
        colors :hurt, %i[transparent orange orange cyan gray]
        hero = sprite :hero, at: [40, 40], facing_from: "/walk.png", tile: 8, dirs: DIRS,
                             colors: %i[transparent red blue yellow magenta]
        hero.face :right
        game_loop { hero.draw_with :hurt }
      end
      builder.finalize_program
    end
    builder.program
  end
end

class TestFacingSheet < Minitest::Test
  include VBlank::Console::Hardware
  include FacingSheetGames

  private def spot(program)
    game_player.run(program).screen.pixel(44, 44)
  end

  # --- a hardware sprite: each row imported to the right direction ---

  # The pose is placed as far behind as the framework draws (Testing#framework_drawing_lag).
  def test_a_hardware_sprite_imports_the_same_way
    assert_equal color(255, 0, 0),   spot(walker(mode: :tiled, face: :down,  run: 1 + framework_drawing_lag)), "tiled: down"
    assert_equal color(255, 255, 0), spot(walker(mode: :tiled, face: :right, run: 1 + framework_drawing_lag)), "tiled: right"
  end

  def test_a_sprite_from_a_directional_sheet_can_be_drawn_with_other_colors
    assert_equal Color.resolve(:cyan), game_player.run(a_recolored_walker, frames: 3).screen.pixel(44, 44)
  end

  # --- friendly errors ---

  private def sprite_error(cols, &block)
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
