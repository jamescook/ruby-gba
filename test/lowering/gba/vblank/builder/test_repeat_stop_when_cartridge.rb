# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_repeat_stop_when"

# A loop that stops as soon as it has its answer, on the Advance's cartridge: where the cartridge
# stops, read in the emulator, and the shape of the ARM loop the lowering picks for it. What the
# loop does on every run is in test/all/vblank/builder/test_repeat_stop_when.rb.
class TestRepeatStopWhenCartridge < Minitest::Test
  include RepeatStopWhenGames

  Build = VBlank::IR::Build
  LoopForm = VBlank::IR::Backends::GBA::LoopForm

  # On the gba run game_player is the interpreter, so this holds the cartridge to it.
  def test_the_console_stops_where_the_interpreter_stops
    backend = GBA.new
    rom = ROM.assemble(backend.lower(marching), title: "STOP", code: "ASTP", maker: "01")
    gba = assert_emulator_loads_rom(rom, frames: 4, vars: backend.var_addresses)

    assert_equal game_player.run(marching, frames: 2)[:steps], gba.var(:steps)
    assert_equal 5, gba.var(:steps)
  end

  # A loop that can stop early works its condition out in the two registers the fast shape keeps
  # its counter and limit in, so it takes the safe shape instead. Dearer per pass, and far
  # cheaper than the passes it does not make.
  def test_an_early_exit_loop_gives_up_the_fast_shape_and_a_plain_one_keeps_it
    plain = Build.repeat(Build.int(4), :i, Build.set(:n, Build.int(1)))
    early = Build.repeat(Build.int(4), :i, Build.set(:n, Build.int(1)),
                         stop_when: Build.var_ref(:done))

    assert LoopForm.counter_in_registers?(plain), "a plain counted loop keeps the registers"
    refute LoopForm.counter_in_registers?(early), "one that can stop early cannot"
    refute LoopForm.stops_early?(plain), "a zero stop condition is nothing to stop for"
    assert LoopForm.stops_early?(early)
  end
end
