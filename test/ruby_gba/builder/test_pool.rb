# frozen_string_literal: true

require "test_helper"

# A pool: many of a component (a thing with named fields that behaves), stamped out
# with a fixed capacity. spawn fills a free slot, each runs the body per live instance
# with a mutable row handle, remove retires one. Behind the scenes it's parallel lists
# + a repeat, so the fields can never desync. Pinned on the reference interpreter.
class TestPool < Minitest::Test
  runs_on :reference

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

  # A POOL TOO BIG TO SHARE THE QUICK MEMORY. The console has 32K of quick memory, which the
  # game's hot code lives in too, and 256K of roomier memory. A pool over the ceiling is kept
  # in the roomier one, where it fits: it is refused only when the game insists on the quick
  # one, and a capacity too big for both memories is the whole-program check's to refuse.

  # The lists a pool was built from, as the program declares them.
  def lists_of(program) = program.walk.select { |node| node.kind == :list_new }

  # A cartridge with a pool :crowd of +capacity+ things of four whole-number fields: 25 bytes
  # a thing, counting the pool's own bookkeeping.
  def crowd_cartridge(capacity:, **words)
    RubyGBA.build("CROWD", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      pool :crowd, x: 0, y: 0, vx: 0, vy: 0, capacity: capacity, **words
      game_loop {}
    end
  end

  # How many bytes of the pool :crowd the built cartridge keeps in the roomier memory.
  def crowd_bytes_in_roomier_memory(rom)
    placed = rom.built.roomy_memory&.collections || {}
    placed.sum { |list, bytes| RubyGBA::Messages::MadeNames.collection_words(list) == "pool :crowd" ? bytes : 0 }
  end

  # 25,000 bytes: more than the ceiling, and far less than the roomier memory holds.
  def test_a_pool_said_to_be_cold_is_not_held_to_the_quick_memorys_ceiling
    assert_equal 25_000, crowd_bytes_in_roomier_memory(crowd_cartridge(capacity: 1000, fast: false)),
                 "the whole of it is in the roomier memory"
  end

  # Nobody has to say so: a pool that cannot share the quick memory goes where it fits.
  def test_a_pool_over_the_ceiling_goes_in_the_roomier_memory_without_being_told
    assert_equal 25_000, crowd_bytes_in_roomier_memory(crowd_cartridge(capacity: 1000))
  end

  # ...and one under it stays in the quick memory, as it always did.
  def test_a_pool_under_the_ceiling_stays_in_the_quick_memory
    assert_equal 0, crowd_bytes_in_roomier_memory(crowd_cartridge(capacity: 32))
  end

  def test_a_pool_over_the_ceiling_that_insists_on_the_quick_memory_is_refused
    message = too_big { pool :crowd, x: 0, y: 0, vx: 0, vy: 0, capacity: 1000, fast: true }

    assert_match(/pool :crowd/, message)
    assert_includes message, RubyGBA::Messages::PlainWords::QUICK_MEMORY, "it names the memory the game asked for"
    assert_match(/remove `fast: true`/, message, "and the way out that keeps the capacity")
  end

  # A POOL NO MEMORY CAN HOLD is refused at its own line, by name. The roomier memory is
  # 256K and a pool over the ceiling is kept there whole, so one bigger than that fits
  # nowhere — whatever else the game declares, and whether or not it said `fast: false`.
  # 10,800 things of 25 bytes are 270,000 bytes: more than the roomier memory, and less than
  # the two memories added together, which is all the whole-program check asks about.
  def test_a_pool_bigger_than_the_roomier_memory_is_refused_by_name
    [{}, { fast: false }].each do |words|
      message = too_big { pool :crowd, x: 0, y: 0, vx: 0, vy: 0, capacity: 10_800, **words }

      assert_match(/pool :crowd/, message)
      assert_match(/roomier memory/, message, "it names the memory the pool would be kept in")
      assert_equal 270_000 / 1024, kilobytes_said(message)
    end
  end

  def test_an_insane_capacity_is_a_friendly_error
    assert_match(/pool :swarm/, too_big { pool :swarm, x: 0, y: 0, capacity: 99_999 })
  end

  # Two pools that each fit the roomier memory and do not fit it together: 135,000 bytes
  # apiece. The one left with no room is named as the pool the game declared, not as one of
  # the lists the framework made it from.
  def test_pools_that_fill_the_roomier_memory_between_them_are_named_as_pools
    error = assert_raises(GBA::LoweringError) do
      RubyGBA.build("TWO", out: StringIO.new, err: StringIO.new) do
        screen :bitmap
        pool :left, x: 0, y: 0, vx: 0, vy: 0, capacity: 5400
        pool :right, x: 0, y: 0, vx: 0, vy: 0, capacity: 5400
        game_loop {}
      end
    end

    assert_match(/pool :(left|right)/, error.message)
    refute_match(/__pool/, error.message, "no name of the framework's own")
  end

  # A pool that draws its instances spends a sprite on each, and the console draws 128: that
  # is what stops a big one that would fit in memory. The words are the sprite check's own
  # and are tested with it; what is pinned here is that such a pool does not build.
  def test_a_big_pool_that_draws_its_instances_does_not_build
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("FLOCK", out: StringIO.new, err: err) do
        screen :tiled
        image(:dot, "#" => :white) { "########\n" * 8 }
        pool :flock, x: 0, y: 0, capacity: 1000, image: :dot, fast: false
        game_loop {}
      end
    end

    assert_match(/pool :flock/, err.string, "the pool is named as what takes the sprites")
  end

  # Every list of a pool said to be cold is kept out of the quick memory, the colours its
  # instances are drawn with among them — a list the pool only gains when one is first told
  # `draw_with`, after the rest are declared.
  def test_a_cold_pool_keeps_the_colors_its_instances_draw_with_out_of_the_quick_memory_too
    rom = RubyGBA.build("COLD", out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image :dot, width: 8, height: 8, data: Array.new(64, :red), colors: %i[transparent red]
      colors :hurt, %i[transparent white]
      crowd = pool :crowd, x: 0, y: 0, capacity: 8, image: :dot, fast: false
      crowd.spawn x: 40, y: 40
      game_loop { crowd.each { |one| one.draw_with :hurt } }
    end
    placed = rom.built.roomy_memory.collections
    quick = rom.built.lists.keys.select do |list|
      RubyGBA::Messages::MadeNames.collection_words(list) == "pool :crowd" && !placed.key?(list)
    end

    assert_empty quick, "these lists of the pool are still in the quick memory"
  end

  # THE COUNT IS OF THE POOL AS IT IS BUILT. A pool is a list per field and a few of its
  # own, each exactly `capacity` slots long and each as wide as it was declared — so that is
  # what is counted. Counting it bigger refuses a pool that fits. These insist on the quick
  # memory, which is what holds a pool to the ceiling.

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

    Builder.new.instance_eval { pool :spark, capacity: 600, widths: narrow, fast: true, **fields }
    assert_match(/spark/, too_big { pool :spark, capacity: 600, fast: true, **fields },
                 "the same pool at a word a field is four times the size")
  end

  # 1000 slots of four word fields: 16 bytes of fields, a byte saying whether the slot is
  # live, and four slot numbers of two bytes each (the free stack and the order they came in).
  def test_a_pool_that_is_too_big_says_the_size_it_would_be_built_at
    message = too_big { pool :swarm, x: 0, y: 0, vx: 0, vy: 0, capacity: 1000, fast: true }

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
      pool :mote, capacity: 1024, widths: narrow, fast: true, **fields
      game_loop {}
    end
    builder.finalize_program
    built = lists_of(builder.program).sum { |node| node.capacity * RubyGBA::IR::Build::ELEMENT_BYTES.fetch(node.width) }

    assert_equal RubyGBA::Builder::Composition::POOL_MAX_QUICK_BYTES, built
    assert_match(/mote/, too_big { pool :mote, capacity: 1025, widths: narrow, fast: true, **fields })
  end

  # A pool with pictures keeps more a slot: which frame each instance is on, and where and
  # what each is in the order they are drawn. Those are in the count as well.
  def test_a_pool_with_pictures_is_counted_with_the_lists_its_pictures_need
    plain = too_big { pool :mote, x: 0, y: 0, capacity: 5000, fast: true }
    drawn = too_big do
      screen :tiled
      image :one, width: 8, height: 8, data: Array.new(64, :red)
      image :two, width: 8, height: 8, data: Array.new(64, :green)
      pool :mote, x: 0, y: 0, capacity: 5000, frames: %i[one two], rate: 4, fast: true
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

  # The same from the roomier memory: a pool too big for the quick one is spawned into,
  # walked and read there like any other, the last of its thousand slots included.
  def test_a_pool_in_the_roomier_memory_draws_on_the_console
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      crowd = pool :crowd, x: 0, y: 0, vx: 0, vy: 0, capacity: 1000
      # Each one tagged with the order it was spawned in, so the first and the last can be
      # picked out whatever slots they landed in.
      repeat(1000) { |i| crowd.spawn x: i % 200, y: 20, vx: i }
      crowd.each { |one| ((one.vx == 0) | (one.vx == 999)).then { draw_rect_at one.x, one.y, 4, 4, :green } }
      game_loop {}
    end
    b.finalize_program

    i = Reference.new.run(b.program, frames: 2)
    assert_equal [GREEN, GREEN], [i.screen.pixel(1, 21), i.screen.pixel(200, 21)], "the interpreter draws both"

    # Filling and walking a thousand slots takes the console several frames.
    v = assert_emulator_loads_rom(assemble_rom(b.program, name: "CROWD"), frames: 40)
    assert v.green?(1, 21), "the first of the crowd drew, got 0x#{format('%04X', v.pixel_gba(1, 21))}"
    assert v.green?(200, 21), "and the last, got 0x#{format('%04X', v.pixel_gba(200, 21))}"
  end
end
