# frozen_string_literal: true

require "test_helper"

require_relative "differential"

# A rectangle whose SIZE the game works out as it runs — the shape a bar or a column
# needs (a health meter that empties, a wall column in a first-person view, a tower that
# grows). `draw_rect_at` used to take a build-time size, so the only way to say it was a
# loop drawing one row-tall rectangle per row.
#
# The interesting cases are the edges. A size of zero, or gone negative from a bar that
# ran past empty: a counted loop that tested its counter the wrong way would draw four
# thousand million rows, and a block fill asked for zero units moves 65536 of them. And
# on the tear-free screen, where a pixel is one byte but the smallest write covers two,
# the parities: which of the rect's end pixels have to be spliced in one at a time
# depends on a width that is not known until it runs.
class TestRuntimeRectSize < Minitest::Test
  include Differential

  def build(&block)
    b = RubyGBA::Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # A bar `height` tall at (40, 20), over a background that makes "not drawn" visible.
  # A tear-free screen draws to a hidden page, so it needs a vblank to present it.
  def bar(height, tear_free: false, x: 40)
    build do
      screen :bitmap, tear_free: tear_free
      var :h, height
      clear_screen :blue
      draw_rect_at x, 20, 20, :h, Color.resolve(:red)
      wait_vblank if tear_free
      halt
    end
  end

  def rows_painted(interp, x: 44)
    (0...160).count { |y| interp.screen.pixel(x, y) == Color.resolve(:red) }
  end

  # --- the height itself ---

  def test_the_rect_is_as_tall_as_the_variable_says
    interp = Reference.new.run(bar(30))

    assert_equal 30, rows_painted(interp)
    assert_equal Color.resolve(:red), interp.screen.pixel(44, 20), "it starts at its y"
    assert_equal Color.resolve(:red), interp.screen.pixel(44, 49), "and ends 30 rows down"
    assert_equal Color.resolve(:blue), interp.screen.pixel(44, 50), "and no further"
  end

  def test_a_height_of_zero_draws_nothing
    assert_equal 0, rows_painted(Reference.new.run(bar(0)))
  end

  # A bar that ran past empty. The row count is a signed compare for exactly this: read
  # as unsigned, -1 rows is four thousand million rows and the frame never ends.
  def test_a_negative_height_draws_nothing
    assert_equal 0, rows_painted(Reference.new.run(bar(-5)))
  end

  # --- the same picture on the console, in both screen modes ---

  def test_the_console_draws_the_same_bar
    assert_backends_agree(bar(30))
  end

  def test_the_console_draws_the_same_bar_when_tear_free
    assert_backends_agree(bar(30, tear_free: true), frames: 2)
  end

  def test_the_console_draws_nothing_for_a_height_of_zero
    assert_backends_agree(bar(0))
  end

  def test_the_console_draws_nothing_for_a_negative_height
    assert_backends_agree(bar(-5))
  end

  # A tear-free screen packs two pixels into each unit it moves, so an odd column is the
  # hard case — the rect's first and last pixel each share a unit with a pixel outside
  # it. That splicing happens per row, so it has to work inside the counted loop too.
  def test_the_console_draws_the_same_bar_at_an_odd_column_when_tear_free
    assert_backends_agree(bar(12, tear_free: true, x: 41), frames: 2)
  end

  # --- narrow columns: what a per-column renderer draws hundreds of ---

  # A column two pixels wide is the cheapest thing this screen can draw: both pixels sit
  # in one 16-bit unit, so a row is a single store with nothing to read first. It is also
  # the case a wrong offset inside the row would break silently, painting the column next
  # door. Every width from one to nine, at both parities, over a background that makes a
  # stray pixel visible.
  def columns(width, x)
    build do
      screen :bitmap, tear_free: true
      var :h, 40
      clear_screen :blue
      draw_rect_at x, 20, width, :h, Color.resolve(:red)
      wait_vblank
      halt
    end
  end

  def test_the_console_draws_a_narrow_column_at_every_width_and_parity
    (1..9).each do |width|
      [40, 41].each do |x|
        assert_backends_agree(columns(width, x), frames: 2)
      end
    end
  end

  # The column must be exactly as wide as asked — a store that ran one unit too far would
  # still agree with itself but paint a neighbour, so the columns on either side are
  # checked against the background directly.
  def test_a_narrow_column_leaves_its_neighbours_alone
    [[2, 40], [2, 41], [4, 41], [1, 40]].each do |width, x|
      interp = Reference.new.run(columns(width, x))
      assert_equal Color.resolve(:blue), interp.screen.pixel(x - 1, 30), "left of a #{width}-wide column at #{x}"
      assert_equal Color.resolve(:red), interp.screen.pixel(x, 30), "the column itself"
      assert_equal Color.resolve(:red), interp.screen.pixel(x + width - 1, 30), "up to its last pixel"
      assert_equal Color.resolve(:blue), interp.screen.pixel(x + width, 30), "and nothing past it"
    end
  end

  # --- a height that changes as the game runs ---

  # The shape this verb exists for: a meter that empties. Each frame the bar is a row
  # shorter, and the row it gave up must go back to the background rather than linger.
  def test_a_shrinking_bar_gives_its_rows_back
    program = build do
      screen :bitmap
      clear_screen :blue
      var :h, 40
      game_loop do
        clear_screen :blue
        sub :h, 1
        draw_rect_at 40, 20, 20, :h, Color.resolve(:red)
      end
    end

    interp = Reference.new.run(program, frames: 10)
    assert_equal 30, rows_painted(interp), "ten frames in, the bar is ten rows shorter"
    assert_equal Color.resolve(:blue), interp.screen.pixel(44, 50), "the rows it gave up are background"
  end

  def test_the_console_agrees_frame_by_frame_as_the_bar_shrinks
    program = build do
      screen :bitmap
      clear_screen :blue
      var :h, 40
      game_loop do
        clear_screen :blue
        sub :h, 1
        draw_rect_at 40, 20, 20, :h, Color.resolve(:red)
      end
    end

    (2..6).each { |f| assert_backends_agree(program, frames: f, name: "SHRINK") }
  end

  # The height may be any expression, not just a variable — and working one out must not
  # disturb the position, which is computed alongside it.
  def test_the_height_can_be_an_expression_worked_out_alongside_the_position
    program = build do
      screen :bitmap
      base = var :base, 10
      top = var :top, 20
      clear_screen :blue
      draw_rect_at base * 4, top + 5, 20, base * 3, Color.resolve(:red)
      halt
    end

    interp = Reference.new.run(program)
    assert_equal 30, rows_painted(interp, x: 44), "the height is base * 3"
    assert_equal Color.resolve(:red), interp.screen.pixel(44, 25), "and the rect starts at top + 5"
    assert_equal Color.resolve(:blue), interp.screen.pixel(44, 24)
    assert_backends_agree(program)
  end

  # Working out one part of a rect must not disturb another. This is a real hazard on the
  # console, not a hypothetical: a multiply of two numbers holding a fraction borrows the
  # very registers the rect's x and y are parked in, so a rect whose y (or height) is such
  # a multiply would have drawn at a corrupted x. The parts go via the stack for this.
  def test_working_out_one_part_of_the_rect_does_not_disturb_the_others
    one = 1 << 16
    program = build do
      screen :bitmap
      clear_screen :blue
      x = var :x, 60
      half = var :half, one / 2 # 0.5, with 16 fraction bits
      forty = var :forty, 40 * one
      # y and the height are each a fraction multiply: 40 * 0.5 = 20, brought back to a
      # whole number of pixels.
      draw_rect_at x, forty.times_fraction(half, fraction_bits: 16) / one,
                   20, forty.times_fraction(half, fraction_bits: 16) / one,
                   Color.resolve(:red)
      halt
    end

    interp = Reference.new.run(program)
    assert_equal Color.resolve(:red), interp.screen.pixel(64, 20), "the rect starts at x=60, y=20"
    assert_equal Color.resolve(:blue), interp.screen.pixel(59, 20), "and not one pixel left of it"
    assert_equal 20, rows_painted(interp, x: 64)
    assert_backends_agree(program)
  end

  # --- a width the game works out ---

  # A bar `width` wide at (x, 20), over a background that makes "not drawn" visible.
  def sideways_bar(width, tear_free: false, x: 40)
    build do
      screen :bitmap, tear_free: tear_free
      var :w, width
      clear_screen :blue
      draw_rect_at x, 20, :w, 6, Color.resolve(:red)
      wait_vblank if tear_free
      halt
    end
  end

  def columns_painted(interp, y: 22)
    (0...240).count { |x| interp.screen.pixel(x, y) == Color.resolve(:red) }
  end

  def test_the_rect_is_as_wide_as_the_variable_says
    interp = Reference.new.run(sideways_bar(30))

    assert_equal 30, columns_painted(interp)
    assert_equal Color.resolve(:red), interp.screen.pixel(40, 22), "it starts at its x"
    assert_equal Color.resolve(:red), interp.screen.pixel(69, 22), "and ends 30 columns along"
    assert_equal Color.resolve(:blue), interp.screen.pixel(70, 22), "and no further"
  end

  def test_a_width_of_zero_or_less_draws_nothing
    assert_equal 0, columns_painted(Reference.new.run(sideways_bar(0)))
    assert_equal 0, columns_painted(Reference.new.run(sideways_bar(-5)))
  end

  def test_the_console_draws_the_same_sideways_bar
    assert_backends_agree(sideways_bar(30))
    assert_backends_agree(sideways_bar(0))
    assert_backends_agree(sideways_bar(-5))
  end

  # The tear-free screen is where a computed width is hard: a pixel is one byte and the
  # smallest write covers two, so the rect's first pixel needs splicing when it starts on
  # an odd column and its last one when it ends on an even column. Which of those apply
  # is not known until the width is. All four combinations, plus the widths where the two
  # ends meet or overlap.
  def test_the_console_draws_a_computed_width_at_every_parity_when_tear_free
    [40, 41].each do |x|
      [1, 2, 3, 4, 7, 30].each do |width|
        assert_backends_agree(sideways_bar(width, tear_free: true, x: x), frames: 2,
                                                                         name: "W#{x}#{width}")
      end
    end
  end

  # The same widths on the plain screen, where a pixel is two bytes and any width is a
  # whole number of transfers — so an odd one must not be quietly rounded.
  def test_the_console_draws_a_computed_width_at_every_parity
    [40, 41].each do |x|
      [1, 2, 3, 7].each { |width| assert_backends_agree(sideways_bar(width, x: x), name: "P#{x}#{width}") }
    end
  end

  # An odd width settled while building used to be refused outright ("the fast block fill
  # moves two pixels per step"). It is no longer a rule the author has to know: the same
  # end-splicing that makes a computed odd width work makes a fixed one work, and the
  # parities are all known while building, so it costs nothing to work out.
  def test_a_fixed_odd_width_is_no_longer_refused
    [40, 41].each do |x|
      [1, 3, 5].each do |width|
        program = build do
          screen :bitmap, tear_free: true
          clear_screen :blue
          draw_rect_at x, 20, width, 4, Color.resolve(:red)
          wait_vblank
          halt
        end

        interp = Reference.new.run(program, frames: 2)
        assert_equal width, columns_painted(interp), "a #{width}-wide rect at x=#{x}"
        assert_equal Color.resolve(:blue), interp.screen.pixel(x - 1, 22), "nothing left of it"
        assert_equal Color.resolve(:blue), interp.screen.pixel(x + width, 22), "nothing right of it"
        assert_backends_agree(program, frames: 2, name: "ODD#{x}#{width}")
      end
    end
  end

  # A bar that empties, one column at a time, past zero and out the other side. This is
  # the shape the verb exists for, and it walks every parity on the way down.
  def test_the_console_agrees_frame_by_frame_as_a_sideways_bar_empties
    program = build do
      screen :bitmap
      clear_screen :blue
      var :w, 8
      game_loop do
        clear_screen :blue
        sub :w, 1
        draw_rect_at 41, 20, :w, 6, Color.resolve(:red)
      end
    end

    (2..8).each { |f| assert_backends_agree(program, frames: f, name: "EMPTY") }
  end

  # Both sizes computed at once, which is the case where nothing about the rect's shape
  # is known while building.
  def test_the_console_draws_a_rect_whose_width_and_height_are_both_worked_out
    program = build do
      screen :bitmap
      clear_screen :blue
      w = var :w, 3
      h = var :h, 5
      draw_rect_at 41, 20, w * 3, h + 2, Color.resolve(:red)
      halt
    end

    interp = Reference.new.run(program)
    assert_equal 9, columns_painted(interp)
    assert_equal 7, rows_painted(interp, x: 44)
    assert_backends_agree(program)
  end

  # --- what it costs ---

  include RubyGBA::IR::Build

  def lowered(node)
    RubyGBA::IR::Backends::GBA.new.lower(program(screen(:bitmap), node, halt))
  end

  # A height settled while building still unrolls its rows, exactly as it always did, so
  # a paddle or a ball costs what it did before this verb learned to take a computed
  # height. Unrolled means each extra row costs the same again — which is what the equal
  # steps here say, and what a loop would flatten.
  def test_a_height_settled_while_building_still_unrolls_its_rows
    sizes = (1..4).map { |h| lowered(draw_rect_at(int(40), int(20), 20, h, :red)).bytesize }
    steps = sizes.each_cons(2).map { |a, b| b - a }

    assert_equal 1, steps.uniq.length, "each extra row should cost the same again: #{sizes.inspect}"
    assert_operator steps.first, :>, 0
  end

  # And the wrapping is invisible: a plain 6 and an int node are the same height, so they
  # must lower to the same bytes.
  def test_a_raw_height_and_an_int_node_lower_alike
    assert_equal lowered(draw_rect_at(int(40), int(20), 20, 6, :red)),
                 lowered(draw_rect_at(int(40), int(20), 20, int(6), :red))
  end
end
