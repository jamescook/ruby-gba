# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_pool_sprites"

# A spriteful pool on the Advance's cartridge: the pools of
# test/all/vblank/dsl/test_pool_sprites.rb, read in the emulator.
class TestPoolSpritesCartridge < Minitest::Test
  include PoolSpritesGames

  # --- hardware ---

  def test_a_spriteful_pool_draws_on_the_console
    prog = enemy_program do |b, enemies|
      enemies.spawn x: 30, y: 30
      enemies.spawn x: 80, y: 80
      b.game_loop { b.wait_vblank }
    end
    rom = ROM.assemble(GBA.new.lower(prog), title: "PSPR", code: "BPSP", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 6)
    assert v.green?(33, 33), "a pooled sprite drew on the console, got 0x#{format('%04X', v.pixel_gba(33, 33))}"
    assert v.green?(83, 83), "and the second one too"
  end

  # --- where a pool stands among the sprites ---

  # Whether the overlap shows the sprite's green on the console.
  private def green_in_front_on_the_console(prog)
    rom = ROM.assemble(GBA.new.lower(prog), title: "PORD", code: "BPOR", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 6)
    v.green?(44, 44)
  end

  def test_a_sprite_declared_after_a_pool_is_in_front_of_it_on_the_console
    assert green_in_front_on_the_console(overlap_program(pool_first: true))
  end

  def test_a_pool_declared_after_a_sprite_is_in_front_of_it_on_the_console
    refute green_in_front_on_the_console(overlap_program(pool_first: false))
  end
end
