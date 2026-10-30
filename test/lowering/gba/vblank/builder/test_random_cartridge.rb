# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_random"

# Randomness on the Advance's cartridge: the same draws land in the same place in the emulator
# as on the interpreter, and a `chance` lowers to the same ARM as the comparison it stands for.
# What every run draws is in test/all/vblank/builder/test_random.rb.
class TestRandomCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include RandomGames

  Build = VBlank::IR::Build

  # A `chance` node means "the random draw is below the threshold". Wrapping the
  # test as a node (so the cost model can see it's a probability) must change no
  # code: it lowers to exactly the same GBA output as that plain comparison. Build
  # both forms and assert identical bytes.
  def test_chance_lowers_identically_to_the_underlying_comparison
    node_form = Build.program(
      Build.screen(:bitmap), Build.set(:d, 0),
      Build.loop_(Build.wait_vblank,
                  Build.if_(Build.chance(Build.var_ref(:d), 30), Build.set(:hit, 1)),
                  Build.halt),
    )
    compare_form = Build.program(
      Build.screen(:bitmap), Build.set(:d, 0),
      Build.loop_(Build.wait_vblank,
                  Build.if_(Build.binop(:<, Build.var_ref(:d), Build.int(30)), Build.set(:hit, 1)),
                  Build.halt),
    )
    assert_equal GBA.new.lower(compare_form), GBA.new.lower(node_form)
  end

  def test_randomize_marker_lands_on_hardware
    program = reaction_program
    # Hold START from the first frame (a fixed timing), so the interpreter's draw
    # position is defined — then confirm the console draws it in the same place.
    x = game_player.input_each_frame { [:start] }.run(program)[:rx]

    rom = VBlank::Cartridge::ROM.assemble(VBlank::IR::Backends::GBA.new.lower(program),
                                          title: "RANDOMIZE", code: "BRDZ", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 5, keys: KEY_START)
    assert v.red?(x, 80), "on the Advance's cartridge: it drew the randomized marker at the same x=#{x}"
  end

  # ---- hardware: the same draws land on the console ----
  #
  # The interpreter and the emulator run the *same* IR, so a marker drawn at a rolled
  # position must land in the same place on both — which confirms the draw works
  # on hardware and that the two backends churn the stream identically.
  def test_interpreter_and_hardware_agree_on_the_drawn_position
    program = marker_program
    i = game_player.run(program)
    x = i[:x]
    y = i[:y]

    rom = VBlank::Cartridge::ROM.assemble(VBlank::IR::Backends::GBA.new.lower(program),
                                          title: "RANDOM", code: "BRND", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 4)
    assert v.red?(x, y), "console drew the marker at the same (#{x},#{y}) the interpreter did"
    assert v.white?(x + 10, y), "and only there — the field beside it is untouched"
  end
end
