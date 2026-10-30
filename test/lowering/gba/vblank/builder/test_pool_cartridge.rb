# frozen_string_literal: true

require "test_helper"
require "stringio"

# A pool on the Advance's cartridge: which of the console's two memories the built cartridge keeps
# it in, and its instances drawn by the cartridge in the emulator. What a pool does, and the
# friendly errors for one too big, are in test/all/vblank/builder/test_pool.rb.
#
# A POOL TOO BIG TO SHARE THE QUICK MEMORY. The console has 32K of quick memory, which the
# game's hot code lives in too, and 256K of roomier memory. A pool over the ceiling is kept
# in the roomier one, where it fits.
class TestPoolCartridge < Minitest::Test
  # A cartridge with a pool :crowd of +capacity+ things of four whole-number fields: 25 bytes
  # a thing, counting the pool's own bookkeeping.
  private def crowd_cartridge(capacity:, **words)
    VBlank.build("CROWD", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      pool :crowd, x: 0, y: 0, vx: 0, vy: 0, capacity: capacity, **words
      game_loop {}
    end
  end

  # How many bytes of the pool :crowd the built cartridge keeps in the roomier memory.
  private def crowd_bytes_in_roomier_memory(rom)
    placed = rom.built.roomy_memory&.collections || {}
    placed.sum { |list, bytes| VBlank::Messages::MadeNames.collection_words(list) == "pool :crowd" ? bytes : 0 }
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

  # Every list of a pool said to be cold is kept out of the quick memory, the colours its
  # instances are drawn with among them — a list the pool only gains when one is first told
  # `draw_with`, after the rest are declared.
  def test_a_cold_pool_keeps_the_colors_its_instances_draw_with_out_of_the_quick_memory_too
    rom = VBlank.build("COLD", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image :dot, width: 8, height: 8, data: Array.new(64, :red), colors: %i[transparent red]
      colors :hurt, %i[transparent white]
      crowd = pool :crowd, x: 0, y: 0, capacity: 8, image: :dot, fast: false
      crowd.spawn x: 40, y: 40
      game_loop { crowd.each { |one| one.draw_with :hurt } }
    end
    placed = rom.built.roomy_memory.collections
    quick = rom.built.lists.keys.select do |list|
      VBlank::Messages::MadeNames.collection_words(list) == "pool :crowd" && !placed.key?(list)
    end

    assert_empty quick, "these lists of the pool are still in the quick memory"
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
