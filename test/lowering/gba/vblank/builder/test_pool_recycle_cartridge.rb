# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_pool_recycle"

# A RECYCLING SPRITE POOL ON THE ADVANCE'S CARTRIDGE, read in the emulator. The pool's `on_full:`
# policy as every run plays it is in test/all/vblank/builder/test_pool_recycle.rb.
class TestPoolRecycleCartridge < Minitest::Test
  include PoolRecycleGames

  def test_recycle_sprite_draws_on_the_console
    rom = ROM.assemble(GBA.new.lower(recycle_sprite_program), title: "RCYC", code: "BRCY", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 6)
    assert v.green?(63, 63), "the recycled sprite drew at the new spawn, got 0x#{format('%04X', v.pixel_gba(63, 63))}"
    assert v.black?(23, 23), "and the old position is clear, got 0x#{format('%04X', v.pixel_gba(23, 23))}"
  end
end
