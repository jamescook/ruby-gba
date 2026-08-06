# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# A pool: many of a component (a thing with named fields that behaves), stamped out
# with a fixed capacity. spawn fills a free slot, each runs the body per live instance
# with a mutable row handle, remove retires one. Behind the scenes it's parallel lists
# + a repeat, so the fields can never desync. Pinned on the reference interpreter.
class TestPool < Minitest::Test
  include GembaSupport

  Builder = RubyGBA::Builder
  Reference = RubyGBA::IR::Backends::Reference
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  GREEN = Color.resolve(:green)
  BLACK = 0

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
    b.emit_pending_functions
    i = Reference.new.run(b.program)

    assert_equal GREEN, i.screen.pixel(10, 12), "first instance drawn at its own (x, y)"
    assert_equal GREEN, i.screen.pixel(40, 30)
    assert_equal GREEN, i.screen.pixel(80, 50)
    assert_equal BLACK, i.screen.pixel(200, 100), "nowhere else"
    assert_equal 3, i[:__pool_bullet_count], "three instances are live"
  end

  # A row handle's field is a mutable Value: b.y.add moves it, b.y.clamp pins it (the
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
          m.y.add 2
          m.y.clamp 0, 80
          draw_rect_at m.x, m.y, 2, 2, :green
        end
      end
    end
    b.emit_pending_functions
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
    b.emit_pending_functions
    i = Reference.new.run(b.program)

    assert_equal GREEN, i.screen.pixel(10, 40), "the others remain"
    assert_equal GREEN, i.screen.pixel(30, 40)
    assert_equal BLACK, i.screen.pixel(20, 40), "the removed one is gone"
    assert_equal 2, i[:__pool_thing_count], "the live count dropped by one"
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
    b.emit_pending_functions
    i = Reference.new.run(b.program)

    assert_equal 3, i[:__pool_p_count], "the pool filled to capacity and the extra spawns were dropped"
  end

  # --- baked guardrails (build-time, friendly errors) ---

  def test_an_insane_capacity_is_a_friendly_error
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval { pool :swarm, x: 0, y: 0, capacity: 99_999 }
    end
    assert_match(/fast RAM/i, err.message)
  end

  def test_a_reserved_field_name_is_a_friendly_error
    b = Builder.new
    err = assert_raises(ArgumentError) do
      b.instance_eval { pool :p, active: 0, capacity: 8 }
    end
    assert_match(/reserved/i, err.message)
  end

  # Cross-backend: a pool is pure sugar over lists + repeat, so the same program lowers
  # to a ROM and draws its live instances on the console (gemba).
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
    b.emit_pending_functions

    rom = ROM.assemble(GBA.new.lower(b.program), title: "POOL", code: "BPOL", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 6)
    assert v.green?(21, 21), "a pooled instance drew on the console, got 0x#{format('%04X', v.pixel_gba(21, 21))}"
    assert v.green?(61, 61), "and the second one too"
  end
end
