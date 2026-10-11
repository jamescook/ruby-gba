# frozen_string_literal: true

require "test_helper"

# A pool: many of a component (a thing with named fields that behaves), stamped out
# with a fixed capacity. spawn fills a free slot, each runs the body per live instance
# with a mutable row handle, remove retires one. Behind the scenes it's parallel lists
# + a repeat, so the fields can never desync. Pinned on the reference interpreter.
class TestPool < Minitest::Test

  GREEN = Color.resolve(:green)
  BLACK = 0

  # The variable a pool keeps how many of its instances are live in.
  def live_count_of(pool) = RubyGBA::DSL::Pool.count_var(pool)

  # spawn several instances with distinct fields; each draws every live one at its own
  # (x, y). Proves spawn, each, per-instance field reads, and that fields stay paired
  # (each instance draws at ITS own x AND y, never a crossed pair).
  def test_spawn_and_each_draw_each_live_instance_at_its_own_fields
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      bullets = pool :bullet, x: 0, y: 0, capacity: 8
      bullets.spawn x: 10, y: 12
      bullets.spawn x: 40, y: 30
      bullets.spawn x: 80, y: 50
      game_loop do
        wait_vblank
        clear_screen :black
        bullets.each { |bl| draw_rect_at bl.x, bl.y, 2, 2, :green }
      end
    end
    b.finalize_program
    i = Reference.new.run(b.program)

    assert_equal GREEN, i.screen.pixel(10, 12), "first instance drawn at its own (x, y)"
    assert_equal GREEN, i.screen.pixel(40, 30)
    assert_equal GREEN, i.screen.pixel(80, 50)
    assert_equal BLACK, i.screen.pixel(200, 100), "nowhere else"
    assert_equal 3, i[live_count_of(:bullet)], "three instances are live"
  end

  # A row handle's field is a mutable Value: b.y.add! moves it, b.y.clamp! pins it (the
  # read-modify-write path through a scratch var). The instance settles at the clamp.
  def test_a_field_is_mutable_per_instance
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      movers = pool :mover, x: 0, y: 0, capacity: 4
      movers.spawn x: 50, y: 10
      game_loop do
        wait_vblank
        clear_screen :black
        movers.each do |m|
          m.y.add! 2
          m.y.clamp! 0, 80
          draw_rect_at m.x, m.y, 2, 2, :green
        end
      end
    end
    b.finalize_program
    i = Reference.new.run(b.program, frames: 45) # the mover needs ~35 frames to reach its clamp

    assert_equal GREEN, i.screen.pixel(50, 80), "it moved down and settled at the clamp"
    assert_equal BLACK, i.screen.pixel(50, 10), "it left its start"
  end

  # remove retires the current instance during each: it stops drawing next frame and
  # the live count drops. Other instances are untouched.
  def test_remove_retires_one_instance
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      things = pool :thing, x: 0, y: 0, capacity: 8
      things.spawn x: 10, y: 40
      things.spawn x: 20, y: 40
      things.spawn x: 30, y: 40
      game_loop do
        wait_vblank
        clear_screen :black
        things.each do |t|
          (t.x == 20).then { t.remove }
          draw_rect_at t.x, t.y, 2, 2, :green
        end
      end
    end
    b.finalize_program
    i = Reference.new.run(b.program)

    assert_equal GREEN, i.screen.pixel(10, 40), "the others remain"
    assert_equal GREEN, i.screen.pixel(30, 40)
    assert_equal BLACK, i.screen.pixel(20, 40), "the removed one is gone"
    assert_equal 2, i[live_count_of(:thing)], "the live count dropped by one"
  end

  # spawn on a full pool is a safe no-op: the count never exceeds capacity and nothing
  # is corrupted.
  def test_spawn_on_a_full_pool_is_a_safe_no_op
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      p = pool :p, x: 0, capacity: 3
      5.times { p.spawn x: 1 } # two more than it can hold
      halt
    end
    b.finalize_program
    i = Reference.new.run(b.program)

    assert_equal 3, i[live_count_of(:p)], "the pool filled to capacity and the extra spawns were dropped"
  end

  # b.index hands back an instance's own slot as a Value. Save it in a variable while
  # comparing across a pool (an each), then reach that exact instance's fields again
  # after the loop with field_ref — proving the slot round-trips to the right instance,
  # not just any one of them.
  def test_index_remembers_which_instance_won_a_comparison
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      found = var :found, -1
      things = pool :thing, x: 0, y: 0, tag: 0, capacity: 8
      things.spawn x: 10, y: 40, tag: 1
      things.spawn x: 20, y: 40, tag: 2
      things.spawn x: 30, y: 40, tag: 3
      game_loop do
        wait_vblank
        clear_screen :black
        things.each { |t| (t.tag == 2).then { found.set! t.index } }
        draw_rect_at things.field_ref(:x, found), 100, 2, 2, :green
      end
    end
    b.finalize_program
    i = Reference.new.run(b.program)

    assert_equal GREEN, i.screen.pixel(20, 100), "index led back to the instance tagged 2 (x=20)"
    assert_equal BLACK, i.screen.pixel(10, 100), "not the instance tagged 1"
    assert_equal BLACK, i.screen.pixel(30, 100), "not the instance tagged 3"
  end

  # --- baked guardrails (build-time, friendly errors) ---

  def test_an_insane_capacity_is_a_friendly_error
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval { pool :swarm, x: 0, y: 0, capacity: 99_999 }
    end
    assert_match(/#{RubyGBA::Messages::PlainWords::QUICK_MEMORY}/, err.message)
  end

  # THE CEILING IS ON THE POOL AS IT IS BUILT. A pool is a list per field and a few of its
  # own, each exactly `capacity` slots long and each as wide as it was declared — so that is
  # what is counted. Counting it bigger refuses a pool that fits.

  def too_big(&game) = assert_raises(ArgumentError) { Builder.new.instance_eval(&game) }.message

  # How many KB the error says the pool needs.
  def kilobytes_said(message) = message[/about (\d+)KB/, 1].to_i

  # A real game's cast: 145 guards of thirteen fields, ten of them narrowed. By its declared
  # widths that is 34 bytes a slot, under five kilobytes.
  def test_a_pool_of_narrow_fields_is_counted_at_the_widths_it_declared
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      pool :guard, a: 0, b: 0, c: 0, d: 0, e: 0, f: 0, g: 0, h: 0, i: 0, j: 0, k: 0, l: 0, m: 0,
                   capacity: 145,
                   widths: { a: :byte, b: :byte, c: :byte, d: :byte, e: :byte, f: :byte, g: :byte,
                             h: :half, i: :half, j: :half }
      game_loop {}
    end
    builder.finalize_program

    assert_operator GBA.new.lower(builder.program).bytesize, :>, 0, "and it builds"
  end

  # None of a pool's lists is a queue the game shifts, so none is rounded up to a power of
  # two: 513 slots are 513 slots, not 1024.
  def test_a_capacity_is_counted_as_given_and_not_rounded_up
    motes = Builder.new.instance_eval { pool :mote, x: 0, y: 0, vx: 0, vy: 0, capacity: 513 }

    assert_equal 513, motes.capacity
  end

  def test_many_slots_of_byte_fields_fit_where_word_fields_would_not
    fields = { a: 0, b: 0, c: 0, d: 0, e: 0, f: 0 }
    narrow = fields.transform_values { :byte }

    Builder.new.instance_eval { pool :spark, capacity: 600, widths: narrow, **fields }
    assert_match(/spark/, too_big { pool :spark, capacity: 600, **fields },
                 "the same pool at a word a field is four times the size")
  end

  # 1000 slots of four word fields: 16 bytes of fields, a byte saying whether the slot is
  # live, and four slot numbers of two bytes each (the free stack and the order they came in).
  def test_a_pool_that_is_too_big_says_the_size_it_would_be_built_at
    message = too_big { pool :swarm, x: 0, y: 0, vx: 0, vy: 0, capacity: 1000 }

    assert_equal (1000 * (16 + 1 + (4 * 2))) / 1024, kilobytes_said(message)
  end

  # WHAT IS COUNTED IS WHAT IS BUILT, to the byte. Seven byte fields, the byte that says a
  # slot is live and four slot numbers of two bytes are sixteen bytes a slot, so 1024 slots
  # are the ceiling exactly — read here off the lists the build was really handed.
  def test_a_pool_exactly_at_the_ceiling_is_built_and_one_slot_more_is_refused
    fields = %i[a b c d e f g].to_h { |field| [field, 0] }
    narrow = fields.transform_values { :byte }
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      pool :mote, capacity: 1024, widths: narrow, **fields
      game_loop {}
    end
    builder.finalize_program
    built = builder.program.walk.select { |node| node.kind == :list_new }
                   .sum { |node| node.capacity * RubyGBA::IR::Build::ELEMENT_BYTES.fetch(node.width) }

    assert_equal RubyGBA::Builder::Composition::POOL_MAX_BYTES, built
    assert_match(/mote/, too_big { pool :mote, capacity: 1025, widths: narrow, **fields })
  end

  # A pool with pictures keeps more a slot: which frame each instance is on, and where and
  # what each is in the order they are drawn. Those are in the count as well.
  def test_a_pool_with_pictures_is_counted_with_the_lists_its_pictures_need
    plain = too_big { pool :mote, x: 0, y: 0, capacity: 5000 }
    drawn = too_big do
      screen :tiled
      image :one, width: 8, height: 8, data: Array.new(64, :red)
      image :two, width: 8, height: 8, data: Array.new(64, :green)
      pool :mote, x: 0, y: 0, capacity: 5000, frames: %i[one two], rate: 4
    end

    assert_operator kilobytes_said(drawn), :>, kilobytes_said(plain)
  end

  # Cross-backend: a pool is pure sugar over lists + repeat, so the same program lowers
  # to a ROM and draws its live instances on the console (the emulator).
  def test_a_pool_lowers_and_draws_on_the_console
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      bullets = pool :bullet, x: 0, y: 0, capacity: 8
      bullets.spawn x: 20, y: 20
      bullets.spawn x: 60, y: 60
      game_loop do
        wait_vblank
        clear_screen :black
        bullets.each { |bl| draw_rect_at bl.x, bl.y, 4, 4, :green }
      end
    end
    b.finalize_program

    rom = ROM.assemble(GBA.new.lower(b.program), title: "POOL", code: "BPOL", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 6)
    assert v.green?(21, 21), "a pooled instance drew on the console, got 0x#{format('%04X', v.pixel_gba(21, 21))}"
    assert v.green?(61, 61), "and the second one too"
  end
end
