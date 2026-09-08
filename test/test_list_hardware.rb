# frozen_string_literal: true

require "test_helper"

# The list feature on real hardware: lower a list program to a ROM, run it in
# gemba, and read the pixels it draws. Each drawing test runs the SAME program on
# the reference interpreter (the oracle) and on the console and asserts identical
# pixels — the cross-backend agreement the list lowering has to hold. The list's
# contents are made visible by drawing a marker at each stored x, so the ring
# buffer's indexing (head + i, wrapped) shows up directly on screen.
#
# Built straight from the IR (not the DSL) so the lowering itself is under test,
# with no sugar in the way. `each` is DSL sugar over repeat + list_get, so here we
# spell that loop out: repeat(list_len, :i) { draw at list_get(:i) }.
class TestListHardware < Minitest::Test
  include RubyGBA::IR::Build

  ROW = 40 # the row every marker is drawn on

  # Draw a 4x4 green marker at each x currently in the list, left to right.
  def draw_each_marker(name)
    repeat(list_len(name), :i,
           draw_rect_at(list_get(name, var_ref(:i)), ROW, 4, 4, :green))
  end

  # Run +prog+ on both backends and assert every [x, colour] holds at row ROW on
  # each. A nil colour means "background here" (black) — nothing drawn.
  def assert_same_markers(prog, expectations)
    screen = Reference.new.run(prog).screen
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

  # A LIST THAT IS NEVER SHIFTED IS A PLAIN ROW OF SLOTS, not a ring, and it is allocated at
  # exactly the size it asked for — no rounding up to a power of two. Its head can never move,
  # so the index IS the slot. This is the shape nearly every list in a real game has (a pool's
  # fields, a board), and the one that used to pay for slots it could never fill.
  #
  # A capacity of five is the point: five is not a power of two, so under the old rule this
  # list held eight and took eight slots' worth of the console's quick memory.
  def test_a_list_that_is_never_shifted_indexes_a_row_of_its_own_size
    prog = program(
      screen(:bitmap), clear_screen(:black),
      list_new(:xs, 5),
      list_push(:xs, 10), list_push(:xs, 10), list_push(:xs, 10),
      list_push(:xs, 10), list_push(:xs, 10),
      list_set(:xs, 0, 20),  # the first slot...
      list_set(:xs, 4, 140), # ...and the last, which is where an off-by-one would show
      list_set(:xs, 2, 80),
      draw_each_marker(:xs),
      halt,
    )

    assert_same_markers(prog,
                        [[20, :green], [10, :green], [80, :green], [140, :green],
                         [50, nil], [110, nil]])
  end

  # ...AND A BAD INDEX STAYS INSIDE IT. There is no mask to confine one on a plain row, so the
  # index is held against the list's own size instead and lands on slot nought. What must never
  # happen is that it reaches the variable next door.
  #
  # A console-only check, like the overflow one below and for the same reason: the interpreter
  # RAISES on an index out of range, which is what catches the logic bug in testing. Hardware
  # has no way to raise, so what it has to do instead is stay bounded, and that is what this
  # reads off the screen.
  def test_an_index_past_the_end_of_a_plain_list_lands_on_its_first_slot
    require_gemba_core!

    prog = program(
      screen(:bitmap), clear_screen(:black),
      set(:sentinel, 70),
      list_new(:xs, 5),
      list_push(:xs, 10), list_push(:xs, 10), list_push(:xs, 10),
      list_set(:xs, 9, 30),   # past the end
      list_set(:xs, -1, 110), # ...and before the start, which as an unsigned number is huge
      draw_each_marker(:xs),
      draw_rect_at(var_ref(:sentinel), ROW, 4, 4, :red),
      halt,
    )

    rom = RubyGBA::ROM.assemble(GBA.new.lower(prog), title: "LISTBD", code: "BLBD", maker: "01")
    v = assert_gemba_loads_rom(rom)
    assert v.pixel_is?(110, ROW, :green), "both bad writes landed on the first slot"
    assert v.pixel_is?(30, ROW, :black), "so the first of them was overwritten by the second"
    assert v.pixel_is?(70, ROW, :red), "and the variable next to the list is untouched"
  end

  # A SLOT NARROWER THAN A WHOLE NUMBER, on the console. The lowering changes for these: the
  # address is scaled by the element size rather than always by four, and the load and store
  # are the byte-sized instructions. So the same markers landing in the same places is the
  # check that all three moved together.
  def test_a_byte_wide_list_indexes_the_same_places_the_oracle_does
    prog = program(
      screen(:bitmap), clear_screen(:black),
      list_new(:xs, 8, width: :byte),
      list_push(:xs, 20),
      list_push(:xs, 60),
      list_push(:xs, 100),
      list_set(:xs, 1, 120), # ...and a write lands on the slot the read comes from
      draw_each_marker(:xs),
      halt,
    )

    assert_same_markers(prog,
                        [[20, :green], [120, :green], [100, :green],
                         [60, nil], [180, nil]])
  end

  # ...AND A NUMBER TOO BIG FOR ONE IS CUT DOWN THE SAME WAY ON BOTH. The console's byte store
  # keeps the low eight bits and there is nothing else it could do; what makes that safe rather
  # than a trap is that the interpreter drops exactly the same bits, so a game tested against
  # the oracle behaves the same on the cartridge. 300 is 256 and 44, and the 256 does not fit.
  def test_a_number_too_big_for_a_byte_slot_is_cut_down_the_same_way_on_both
    prog = program(
      screen(:bitmap), clear_screen(:black),
      list_new(:xs, 4, width: :byte),
      list_push(:xs, 300),
      draw_each_marker(:xs),
      halt,
    )

    assert_same_markers(prog, [[44, :green], [300 % 240, nil], [20, nil]])
  end

  # A SIGNED narrow slot reads back below nothing, which is what a -1 meaning "none" needs.
  # Read by drawing at 100 plus what came out, so a slot that lost the sign draws at 355 —
  # off the screen — and one that kept it draws at 99.
  def test_a_signed_byte_slot_reads_a_negative_back_on_both_backends
    prog = program(
      screen(:bitmap), clear_screen(:black),
      list_new(:xs, 4, width: :byte),
      list_push(:xs, -1),
      repeat(list_len(:xs), :i,
             draw_rect_at(binop(:+, int(100), list_get(:xs, var_ref(:i))), ROW, 4, 4, :green)),
      halt,
    )

    # 99 is where a kept sign lands; a lost one would be 100 + 255, off the screen entirely.
    assert_same_markers(prog, [[99, :green], [95, nil], [104, nil]])
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
