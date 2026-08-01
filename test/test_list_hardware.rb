# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# The list feature on real hardware: lower a list program to a ROM, run it in
# gemba, and read the pixels it draws. Each drawing test runs the SAME program on
# the Ruby interpreter (the oracle) and on the console and asserts identical
# pixels — the cross-backend agreement the list lowering has to hold. The list's
# contents are made visible by drawing a marker at each stored x, so the ring
# buffer's indexing (head + i, wrapped) shows up directly on screen.
#
# Built straight from the IR (not the DSL) so the lowering itself is under test,
# with no sugar in the way. `each` is DSL sugar over repeat + list_get, so here we
# spell that loop out: repeat(list_len, :i) { draw at list_get(:i) }.
class TestListHardware < Minitest::Test
  include RubyGBA::IR::Build
  include GembaSupport

  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  Color = RubyGBA::Color

  ROW = 40 # the row every marker is drawn on

  # Draw a 4x4 green marker at each x currently in the list, left to right.
  def draw_each_marker(name)
    repeat(list_len(name), :i,
           draw_rect_at(list_get(name, var_ref(:i)), ROW, 4, 4, :green))
  end

  # Run +prog+ on both backends and assert every [x, colour] holds at row ROW on
  # each. A nil colour means "background here" (black) — nothing drawn.
  def assert_same_markers(prog, expectations)
    screen = Ruby.new.run(prog).screen
    expectations.each do |x, color|
      want = Color.resolve(color || :black)
      assert_equal want, screen.pixel(x, ROW),
                   "interpreter: (#{x}, #{ROW}) should be #{color || 'background'}"
    end

    rom = RubyGBA::ROM.assemble(GBA.new.lower(prog), title: "LISTHW", code: "BLHW", maker: "01")
    v = assert_gemba_loads_rom(rom)
    expectations.each do |x, color|
      assert v.pixel_is?(x, ROW, color || :black),
             "console: (#{x}, #{ROW}) should be #{color || 'background'}, " \
             "got 0x#{format('%04X', v.pixel_gba(x, ROW))}"
    end
  end

  def test_draws_each_item_by_index
    # Push three x positions and draw a marker at each. Both backends must place
    # markers at exactly 20/60/100 and leave the gaps between them background.
    prog = program(
      screen(:bitmap), clear_screen(:black),
      list_new(:xs, 8),
      list_push(:xs, 20),
      list_push(:xs, 60),
      list_push(:xs, 100),
      draw_each_marker(:xs),
      halt,
    )

    assert_same_markers(prog,
                        [[20, :green], [60, :green], [100, :green],
                         [0, nil], [40, nil], [80, nil]])
  end

  def test_shift_advances_the_ring_head
    # Drop the oldest (20), so the head moves on and only 60/100 remain. Reading
    # index 0 must now land on 60 — this is the ring wrap in action, and both
    # backends must agree the 20 marker is gone.
    prog = program(
      screen(:bitmap), clear_screen(:black),
      list_new(:xs, 8),
      list_push(:xs, 20),
      list_push(:xs, 60),
      list_push(:xs, 100),
      list_drop(:xs, from: :front), # shift: drop 20
      draw_each_marker(:xs),
      halt,
    )

    assert_same_markers(prog,
                        [[20, nil], [60, :green], [100, :green]])
  end

  def test_pop_drops_the_newest
    # Pop removes the last pushed (100); 20/60 remain.
    prog = program(
      screen(:bitmap), clear_screen(:black),
      list_new(:xs, 8),
      list_push(:xs, 20),
      list_push(:xs, 60),
      list_push(:xs, 100),
      list_drop(:xs, from: :back), # pop: drop 100
      draw_each_marker(:xs),
      halt,
    )

    assert_same_markers(prog,
                        [[20, :green], [60, :green], [100, nil]])
  end

  def test_index_assignment_and_wraparound_after_many_shifts
    # Shift/push repeatedly so head wraps past the end of the ring (capacity 4),
    # then overwrite index 0. Exercises (head + i) & mask for a non-zero head.
    prog = program(
      screen(:bitmap), clear_screen(:black),
      list_new(:xs, 4),
      list_push(:xs, 10), list_push(:xs, 10), list_push(:xs, 10),
      list_drop(:xs, from: :front), # head -> 1
      list_drop(:xs, from: :front), # head -> 2
      list_push(:xs, 70),           # tail wraps into an early physical slot
      list_push(:xs, 110),          # and again
      list_set(:xs, 0, 30),         # overwrite the logical first (physical slot 3)
      draw_each_marker(:xs),        # now [30, 70, 110]
      halt,
    )

    assert_same_markers(prog,
                        [[30, :green], [70, :green], [110, :green],
                         [10, nil], [50, nil]])
  end

  def test_overflow_is_bounded_on_hardware
    # The interpreter *raises* on a push past capacity; hardware can't, so it must
    # instead bound the list safely — drop the extra pushes, keep the oldest two,
    # and never let length run past capacity. So this is a console-only check: push
    # four into a capacity-2 list and confirm exactly the first two (30, 90) are
    # drawn, with the overflowing 150/210 absent.
    require_gemba_core!

    prog = program(
      screen(:bitmap), clear_screen(:black),
      list_new(:xs, 2),
      list_push(:xs, 30),
      list_push(:xs, 90),
      list_push(:xs, 150), # full -> dropped
      list_push(:xs, 210), # full -> dropped
      draw_each_marker(:xs),
      halt,
    )

    rom = RubyGBA::ROM.assemble(GBA.new.lower(prog), title: "LISTOF", code: "BLOF", maker: "01")
    v = assert_gemba_loads_rom(rom)
    assert v.pixel_is?(30, ROW, :green), "the first push survives"
    assert v.pixel_is?(90, ROW, :green), "the second push survives"
    assert v.pixel_is?(150, ROW, :black), "the overflowing third push is dropped"
    assert v.pixel_is?(210, ROW, :black), "the overflowing fourth push is dropped"
  end
end
