# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_pool_poses"

# A POOLED THING'S POSES ON THE ADVANCE'S CARTRIDGE, read in the emulator. Each instance facing
# and animating on its own, on every run, is in test/all/vblank/dsl/test_pool_poses.rb.
class TestPoolPosesCartridge < Minitest::Test
  include PoolPosesGames

  def test_the_console_cycles_a_pool_declared_inside_a_scene
    rom = ROM.assemble(GBA.new.lower(scene_pool_program), title: "POOLSCENE")
    v = assert_emulator_loads_rom(rom, frames: 3)
    seen = Array.new(6) do
      v.step
      %i[red blue].find { |color| v.pixel_is?(22, 22, color) }
    end

    assert_includes seen, :red
    assert_includes seen, :blue, "the second picture is shown too"
  end

  # --- the console draws the same thing ---

  def test_the_console_draws_each_instance_facing_its_own_way
    prog = pool_program(facing: { left: :left1, right: :right1 }) do |b, guards|
      guards.spawn x: 20, y: 20
      guards.spawn x: 60, y: 20
      b.game_loop do
        b.wait_vblank
        guards.each { |g| (g.x == 20).then { g.face :left }.else { g.face :right } }
      end
    end

    rom = ROM.assemble(GBA.new.lower(prog), title: "POOLFACE", code: "BPLF", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 4)
    assert v.pixel_is?(22, 22, :red), "got 0x#{format('%04X', v.pixel_gba(22, 22))}"
    assert v.pixel_is?(62, 22, :green), "got 0x#{format('%04X', v.pixel_gba(62, 22))}"
  end
end
