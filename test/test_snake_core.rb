# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The Snake move/collision core — the focused integration test for the list
# feature. It isn't the whole game (that's examples/snake.rb); it's the part that
# leans on everything the `list` work delivered at once, written in the DSL a
# person would actually use:
#
#   * two parallel lists (xs, ys) for the body's cells,
#   * push/shift to move (grow a head, drop a tail),
#   * `repeat(body.length)` to scan the body at run time,
#   * the expression DSL to compute the new head and test a self-collision
#     (xs[i] == head_x) & (ys[i] == head_y).
#
# The collision logic is checked on the Ruby interpreter (the oracle — the whole
# point is that game logic is testable headlessly), and the same drawing stack is
# checked on real hardware via gemba, so the core is proven on both backends.
class TestSnakeCore < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  Color = RubyGBA::Color

  # Build a snake whose body starts at +start_cells+ (an array of [x, y]) and then
  # walks +moves+ (an array of [dx, dy]). If +grow+ is true the body keeps every
  # cell (push only); otherwise it slides (push a head, shift the tail). Before
  # each head is added, the body is scanned for a cell the new head would land on
  # — a self-bite — which sets :hit to 1. Returned as a finished interpreter run.
  def run_snake(start_cells:, moves:, grow:)
    builder = Builder.new
    builder.instance_eval do
      display :bitmap
      xs = list :xs, capacity: 64
      ys = list :ys, capacity: 64
      var :hit, 0
      start_cells.each do |cx, cy|
        xs.push cx
        ys.push cy
      end
      moves.each do |dx, dy|
        set :hx, xs.last + dx
        set :hy, ys.last + dy
        # Scan the current body: does the new head land on an existing cell?
        repeat(xs.length) { |i| ((xs[i] == :hx) & (ys[i] == :hy)).then { set :hit, 1 } }
        xs.push :hx
        ys.push :hy
        unless grow
          xs.shift
          ys.shift
        end
      end
      halt
    end
    builder.emit_pending_functions
    Ruby.new.run(builder.program)
  end

  def test_a_growing_snake_that_loops_back_bites_itself
    # Start at (5,5), then right/down/left/up — a unit square that brings the head
    # back onto the starting cell (5,5), which is still in the body. Collision.
    result = run_snake(
      start_cells: [[5, 5]],
      moves: [[1, 0], [0, 1], [-1, 0], [0, -1]],
      grow: true,
    )

    assert_equal 1, result[:hit], "returning onto a body cell is a self-collision"
  end

  def test_a_snake_moving_in_a_straight_line_never_collides
    # Four steps right, growing — every cell distinct, so no bite.
    result = run_snake(
      start_cells: [[5, 5]],
      moves: [[1, 0], [1, 0], [1, 0], [1, 0]],
      grow: true,
    )

    assert_equal 0, result[:hit], "a straight path never bites itself"
  end

  def test_a_sliding_snake_does_not_bite_the_tail_it_vacates
    # A 3-cell snake sliding straight: the tail moves out of the way each step, so
    # the head never lands on a *current* body cell. No collision.
    result = run_snake(
      start_cells: [[2, 5], [3, 5], [4, 5]],
      moves: [[1, 0], [1, 0]],
      grow: false,
    )

    assert_equal 0, result[:hit], "the sliding tail is never bitten"
  end

  def test_sliding_tracks_the_head_and_tail_positions
    # Body [(2,5),(3,5),(4,5)] slides right twice with a fixed length of 3. After
    # two steps it should be [(4,5),(5,5),(6,5)] — read the ends back to confirm
    # push+shift moved the whole body, not just an end.
    builder = Builder.new
    builder.instance_eval do
      display :bitmap
      xs = list :xs, capacity: 64
      ys = list :ys, capacity: 64
      [[2, 5], [3, 5], [4, 5]].each { |cx, cy| xs.push cx; ys.push cy }
      2.times do
        set :hx, xs.last + 1
        xs.push :hx
        ys.push 5 # the body slides along row 5; only x changes here
        xs.shift
        ys.shift
      end
      set :tail_x, xs.first
      set :head_x, xs.last
      set :len, xs.length
      halt
    end
    builder.emit_pending_functions
    result = Ruby.new.run(builder.program)

    assert_equal 3, result[:len], "length stays fixed while sliding"
    assert_equal 4, result[:tail_x], "the tail advanced to the old second cell"
    assert_equal 6, result[:head_x], "the head advanced two steps"
  end

  def test_the_body_draws_the_same_on_both_backends
    # The list-driven draw loop (repeat over the body, draw each cell by index)
    # must render identically headless and on the console. Slide a 3-cell snake
    # right once, then draw it; assert the three cells are green and the vacated
    # tail cell is background — on the interpreter AND in gemba.
    grid = 4
    builder = Builder.new
    builder.instance_eval do
      display :bitmap
      clear_screen :black
      xs = list :xs, capacity: 64
      ys = list :ys, capacity: 64
      [[2, 5], [3, 5], [4, 5]].each { |cx, cy| xs.push cx; ys.push cy }
      # slide right once -> body [(3,5),(4,5),(5,5)]
      set :hx, xs.last + 1
      xs.push :hx
      ys.push 5
      xs.shift
      ys.shift
      repeat(xs.length) { |i| draw_rect_at xs[i] * grid, ys[i] * grid, grid, grid, :green }
      halt
    end
    builder.emit_pending_functions
    prog = builder.program

    # cells (3,5),(4,5),(5,5) at grid 4 -> x = 12,16,20 ; y = 20. Vacated (2,5) -> x=8.
    marks = { 12 => :green, 16 => :green, 20 => :green, 8 => :black }

    screen = Ruby.new.run(prog).screen
    marks.each do |x, color|
      assert_equal Color.resolve(color), screen.pixel(x, 20),
                   "interpreter: (#{x}, 20) should be #{color}"
    end

    rom = RubyGBA::ROM.assemble(GBA.new.lower(prog), title: "SNAKE", code: "BSNK", maker: "01")
    v = assert_gemba_loads_rom(rom)
    marks.each do |x, color|
      assert v.pixel_is?(x, 20, color),
             "console: (#{x}, 20) should be #{color}, got 0x#{format('%04X', v.pixel_gba(x, 20))}"
    end
  end
end
