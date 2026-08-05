# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Scrolling cannot tear, however much work a frame does.
#
# The display re-reads a background's scroll position for every line it draws. So
# a game that works out its camera position and writes it while the picture is
# being drawn moves only the lines below that point, and the screen shears in
# half. The later in the frame the write lands, the further down the shear sits.
#
# A game should not have to know any of that, so the write is not made where the
# game computes it. `scroll_to`/`scroll_by` set the camera position, and the
# framework writes it once a frame in the gap between frames, next to the sprites.
# Then no amount of per-frame work can put the write in the wrong place.
#
# The test for that is a game that deliberately does far too much work before
# scrolling. Its column of pixels has to come out one flat color: two colors in a
# column means the picture sheared, and where it changes is where the write landed.
class TestScrollTearing < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  GBA = RubyGBA::IR::Backends::GBA
  Ruby = RubyGBA::IR::Backends::Ruby
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  SOLID8 = (["########"] * 8).join("\n")

  # A field of alternating 8px red and blue columns, scrolled 8px further every
  # frame — so any horizontal shift changes which color sits at a given x, and a
  # shear shows as one column of screen holding two colors. +work+ is busywork done
  # before the scroll, to push the write later and later into the frame.
  def striped_scroller(work)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:red_t, "#" => :red) { SOLID8 }
      image(:blue_t, "#" => :blue) { SOLID8 }
      tiles :stripes, "R" => :red_t, "B" => :blue_t
      bg = background :field, tiles: :stripes,
                              map: Array.new(32) { (0...32).map { |c| c.even? ? "R" : "B" }.join }
      x = var :x, 0
      game_loop do
        repeat(work) { add :x, 0 } if work.positive?
        x.add 8
        bg.scroll_to x, 0
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  # Enough busywork that the scroll would land well past the safe window if it were
  # written where the game asks for it. Measured before this was fixed: at 800 the
  # shear sat at line 1, at 1000 line 18, at 1200 line 35, at 1500 line 61 — the
  # shear marching down the screen as the work grew.
  WORK_LEVELS = [800, 1000, 1200, 1500].freeze

  def test_a_late_scroll_does_not_tear_on_the_console
    WORK_LEVELS.each do |work|
      rom = ROM.assemble(GBA.new.lower(striped_scroller(work)),
                         title: "SCROLL", code: "BSCR", maker: "01")
      v = assert_gemba_loads_rom(rom, frames: 8)

      column = (0...160).map { |y| v.pixel_gba(4, y) }
      shear = (1...160).find { |y| column[y] != column[y - 1] }
      assert_nil shear,
                 "with #{work} units of work before it, the scroll sheared the picture at line " \
                 "#{shear} — the whole column should be one color"
    end
  end

  # Scrolling from inside a branch is the shape a real game has — a camera that
  # follows a held button, so the scroll happens on some frames and not others. The
  # write still lands in the gap between frames, and the view still moves.
  #
  # A lone green landmark on a blue field, because a repeating pattern cannot show
  # movement: the stripes above scroll by exactly their own width, so they look the
  # same wherever they are.
  def test_scrolling_from_inside_a_branch_still_moves_the_view
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:blue_t, "#" => :blue) { SOLID8 }
      image(:green_t, "#" => :green) { SOLID8 }
      tiles :field, "B" => :blue_t, "G" => :green_t
      map = Array.new(32) { |r| (0...32).map { |c| r == 5 && c == 5 ? "G" : "B" }.join }
      bg = background :world, tiles: :field, map: map
      x = var :x, 0
      game_loop do
        held(:right).then { x.add 4; bg.scroll_to x, 0 }
      end
    end
    builder.emit_pending_functions
    program = builder.program

    still = Ruby.new.run(program, frames: 6).screen
    moved = Ruby.new.hold(:right).run(program, frames: 6).screen

    assert_equal Color.resolve(:green), still.pixel(44, 44),
                 "left alone, the landmark stays where the map put it"
    assert_equal Color.resolve(:blue), moved.pixel(44, 44),
                 "holding right scrolls the world, so the landmark has moved off that spot"
  end
end
