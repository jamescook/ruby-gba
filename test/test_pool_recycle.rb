# frozen_string_literal: true

require "test_helper"

# A pool's `on_full:` policy. By default a spawn onto a full pool is a safe no-op
# (:drop). With `on_full: :recycle_oldest` a full spawn instead reuses the longest-lived
# instance so a new one always appears — the usual choice for particles and effects.
# Behind the scenes the pool stamps each spawn with its order and, when full, reuses the
# slot with the oldest stamp — true age, not slot position, so it stays correct even
# after removes shuffle the free slots. Pinned on the interpreter and on gemba.
class TestPoolRecycle < Minitest::Test

  GREEN = Color.resolve(:green)
  BLACK = 0

  # Build a data pool of `thing`s (a single `tag` field) with the given policy, spawn the
  # given tags in order, then record which tags are live and how many. Returns the
  # interpreter so a test can read :saw<tag> flags, :total, and the pool count.
  def run_tags(policy, capacity, spawn_tags, remove_tag: nil)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      %i[saw1 saw2 saw3 saw4 saw5].each { |v| var v, 0 }
      var :total, 0
      things = pool :thing, tag: 0, capacity: capacity, on_full: policy
      spawn_tags.each_with_index do |tag, i|
        things.spawn tag: tag
        # Optionally remove one instance partway through, to free a slot before a later
        # spawn — so "oldest" is tested by age, not by which slot happens to be free.
        things.each { |t| (t.tag == remove_tag).then { t.remove } } if remove_tag && i == 1
      end
      things.each do |t|
        (1..5).each { |n| (t.tag == n).then { set :"saw#{n}", 1 } }
        add :total, 1
      end
      halt
    end
    b.emit_pending_functions
    Reference.new.run(b.program)
  end

  # The default: a full pool drops the extra spawn — the two originals stay, the third
  # never appears.
  def test_default_policy_drops_the_spawn_when_full
    i = run_tags(:drop, 2, [1, 2, 3])
    assert_equal 1, i[:saw1], "the first instance is kept"
    assert_equal 1, i[:saw2], "the second instance is kept"
    assert_equal 0, i[:saw3], "the third spawn was dropped (pool was full)"
    assert_equal 2, i[:total]
    assert_equal 2, i[:__pool_thing_count]
  end

  # recycle_oldest: a full spawn replaces the OLDEST instance (tag 1), keeps the rest,
  # and the new one appears — count stays at capacity (reused, not grown).
  def test_recycle_oldest_replaces_the_oldest_when_full
    i = run_tags(:recycle_oldest, 2, [1, 2, 3])
    assert_equal 0, i[:saw1], "the oldest instance (tag 1) was recycled, not kept"
    assert_equal 1, i[:saw2], "the newer instance stays"
    assert_equal 1, i[:saw3], "the new spawn appeared"
    assert_equal 2, i[:total], "still exactly capacity live — reused a slot, didn't grow"
    assert_equal 2, i[:__pool_thing_count]
  end

  # "Oldest" is by spawn age, not slot: remove a middle instance (freeing its slot), spawn
  # into that freed slot, then overflow — the recycled one must be the genuinely oldest
  # survivor, not whichever slot was most recently free.
  def test_recycle_oldest_is_by_age_even_after_a_remove
    # spawn 1, 2, 3 (full); remove tag 2 after the 2nd spawn; spawn 4 (into the freed
    # slot); spawn 5 (full again) -> recycles tag 1, the oldest survivor.
    i = run_tags(:recycle_oldest, 3, [1, 2, 3, 4, 5], remove_tag: 2)
    assert_equal 0, i[:saw1], "tag 1 is the oldest survivor and is recycled"
    assert_equal 0, i[:saw2], "tag 2 was removed earlier"
    assert_equal 1, i[:saw3], "tag 3 stays"
    assert_equal 1, i[:saw4], "tag 4 (spawned into the freed slot) stays"
    assert_equal 1, i[:saw5], "tag 5 (the newest) appeared"
    assert_equal 3, i[:__pool_thing_count]
  end

  # An unknown policy is a friendly build error, naming the valid choices.
  def test_an_unknown_on_full_policy_is_a_friendly_error
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :bitmap
        pool :thing, x: 0, capacity: 4, on_full: :explode
      end
    end
    assert_match(/on_full/, err.message)
    assert_match(/recycle_oldest/, err.message)
  end

  # --- cross-backend: a spriteful recycle pool, on the interpreter and on gemba ---

  # A capacity-1 recycling sprite pool: spawn at one spot, then (full) spawn at another —
  # the single instance moves to the new spot and the old one is vacated. A clean pixel
  # proof of recycle that both backends must agree on.
  def recycle_sprite_program
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:dot, "#" => :green) { "########\n" * 8 }
      dots = pool :dot, x: 0, y: 0, capacity: 1, image: :dot, on_full: :recycle_oldest
      dots.spawn x: 20, y: 20
      dots.spawn x: 60, y: 60 # full (capacity 1) -> recycles the only instance to here
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    b.program
  end

  def test_recycle_sprite_moves_to_the_new_spawn_on_the_interpreter
    i = Reference.new.run(recycle_sprite_program)
    assert_equal GREEN, i.screen.pixel(62, 62), "the recycled instance draws at the new spawn"
    assert_equal BLACK, i.screen.pixel(22, 22), "and the old position is vacated"
  end

  def test_recycle_sprite_draws_on_the_console
    rom = ROM.assemble(GBA.new.lower(recycle_sprite_program), title: "RCYC", code: "BRCY", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)
    assert v.green?(63, 63), "the recycled sprite drew at the new spawn, got 0x#{format('%04X', v.pixel_gba(63, 63))}"
    assert v.black?(23, 23), "and the old position is clear, got 0x#{format('%04X', v.pixel_gba(23, 23))}"
  end
end
