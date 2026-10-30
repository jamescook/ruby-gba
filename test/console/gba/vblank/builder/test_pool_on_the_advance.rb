# frozen_string_literal: true

require "test_helper"

# THE TESTS OF vblank/builder/test_pool.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (test/console/gba); the rest are in that file.
#
# A pool: many of a component (a thing with named fields that behaves), stamped out
# with a fixed capacity. spawn fills a free slot, each runs the body per live instance
# with a mutable row handle, remove retires one. Behind the scenes it's parallel lists
# + a repeat, so the fields can never desync. Pinned on the reference interpreter.
#
# The same crowd drawn by the Advance's cartridge in the emulator is in
# test/lowering/gba/vblank/builder/test_pool_on_the_advance_cartridge.rb.

# The game both files play.
module PoolOnTheAdvanceGames
  # A pool of a thousand, too big for the quick memory, that draws the first and the last spawned.
  private def crowd_of_a_thousand
    b = VBlank::Builder.new
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
    b.program
  end
end

class TestPoolOnTheAdvance < Minitest::Test
  include PoolOnTheAdvanceGames

  GREEN = Color.resolve(:green)

  # The same from the roomier memory: a pool too big for the quick one is spawned into,
  # walked and read there like any other, the last of its thousand slots included.
  def test_a_pool_in_the_roomier_memory_draws_on_the_console
    i = game_player.run(crowd_of_a_thousand, frames: 2)
    assert_equal [GREEN, GREEN], [i.screen.pixel(1, 21), i.screen.pixel(200, 21)], "the interpreter draws both"
  end
end
