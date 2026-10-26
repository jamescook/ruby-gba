# frozen_string_literal: true

require "test_helper"

# THE TESTS OF ruby_gba/builder/test_pool.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# A pool: many of a component (a thing with named fields that behaves), stamped out
# with a fixed capacity. spawn fills a free slot, each runs the body per live instance
# with a mutable row handle, remove retires one. Behind the scenes it's parallel lists
# + a repeat, so the fields can never desync. Pinned on the reference interpreter.
class TestPoolOnTheAdvance < Minitest::Test
  GREEN = Color.resolve(:green)
  BLACK = 0

  # The variable a pool keeps how many of its instances are live in.
  private def live_count_of(pool) = RubyGBA::DSL::Pool.count_var(pool)

  # --- baked guardrails (build-time, friendly errors) ---

  # A POOL TOO BIG TO SHARE THE QUICK MEMORY. The console has 32K of quick memory, which the
  # game's hot code lives in too, and 256K of roomier memory. A pool over the ceiling is kept
  # in the roomier one, where it fits: it is refused only when the game insists on the quick
  # one, and a capacity too big for both memories is the whole-program check's to refuse.

  # The lists a pool was built from, as the program declares them.
  private def lists_of(program) = program.walk.select { |node| node.kind == :list_new }

  # A cartridge with a pool :crowd of +capacity+ things of four whole-number fields: 25 bytes
  # a thing, counting the pool's own bookkeeping.
  private def crowd_cartridge(capacity:, **words)
    RubyGBA.build("CROWD", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      pool :crowd, x: 0, y: 0, vx: 0, vy: 0, capacity: capacity, **words
      game_loop {}
    end
  end

  # How many bytes of the pool :crowd the built cartridge keeps in the roomier memory.
  private def crowd_bytes_in_roomier_memory(rom)
    placed = rom.built.roomy_memory&.collections || {}
    placed.sum { |list, bytes| RubyGBA::Messages::MadeNames.collection_words(list) == "pool :crowd" ? bytes : 0 }
  end

  # THE COUNT IS OF THE POOL AS IT IS BUILT. A pool is a list per field and a few of its
  # own, each exactly `capacity` slots long and each as wide as it was declared — so that is
  # what is counted. Counting it bigger refuses a pool that fits. These insist on the quick
  # memory, which is what holds a pool to the ceiling.

  private def too_big(&game) = assert_raises(ArgumentError) { Builder.new.instance_eval(&game) }.message

  # How many KB the error says the pool needs.
  private def kilobytes_said(message) = message[/about (\d+)KB/, 1].to_i

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

    i = game_player.run(b.program, frames: 2)
    assert_equal [GREEN, GREEN], [i.screen.pixel(1, 21), i.screen.pixel(200, 21)], "the interpreter draws both"

    # Filling and walking a thousand slots takes the console several frames.
    v = assert_emulator_loads_rom(assemble_rom(b.program, name: "CROWD"), frames: 40)
    assert v.green?(1, 21), "the first of the crowd drew, got 0x#{format('%04X', v.pixel_gba(1, 21))}"
    assert v.green?(200, 21), "and the last, got 0x#{format('%04X', v.pixel_gba(200, 21))}"
  end
end
