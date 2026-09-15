# frozen_string_literal: true

require "test_helper"

# Reading run-time state back off real hardware. the emulator reads the GBA bus directly,
# so the Verifier can assert what a program actually COMPUTED (a variable in IWRAM)
# and read hardware registers (VCOUNT) — not just what's on screen. This is the
# readout channel the draw-cost timing probe will use, and a general way to assert
# state on hardware. Needs the backend's variable-address map, since the backend —
# not the builder — decides where each variable lives.
class TestVerifierMemory < Minitest::Test

  ANSWER = 51_966 # 0xCAFE — a distinctive sentinel

  # A ROM that computes a couple of variables and halts, plus the backend that
  # lowered it (so we know where the variables live).
  def computed_rom
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      set! :answer, ANSWER
      set! :doubled, 0
      add! :doubled, :answer
      add! :doubled, :answer # doubled = 2 * answer
      halt
    end
    builder.emit_pending_functions
    backend = GBA.new
    bytes = backend.lower(builder.program)
    [ROM.assemble(bytes, title: "MEMTEST", code: "BMEM", maker: "01"), backend]
  end

  def test_reads_a_variable_by_name_on_hardware
    rom, backend = computed_rom
    v = assert_emulator_loads_rom(rom, frames: 3, vars: backend.var_addresses)
    assert_equal ANSWER, v.var(:answer), "the ROM's :answer wasn't read back from IWRAM"
    assert_equal ANSWER * 2, v.var(:doubled), "the computed :doubled wasn't read back"
  end

  def test_reads_memory_by_raw_address
    rom, backend = computed_rom
    v = assert_emulator_loads_rom(rom, frames: 3, vars: backend.var_addresses)
    assert_equal ANSWER, v.mem32(backend.var_addresses.fetch(:answer))
  end

  def test_reads_the_vcount_register
    rom, backend = computed_rom
    v = assert_emulator_loads_rom(rom, frames: 3, vars: backend.var_addresses)
    # VCOUNT (0x04000006) is the scanline being drawn — a frame boundary sits in vblank.
    assert_includes 0..227, v.mem16(0x0400_0006), "VCOUNT should be a scanline number"
  end

  def test_an_unknown_variable_is_a_friendly_error
    rom, backend = computed_rom
    v = assert_emulator_loads_rom(rom, frames: 2, vars: backend.var_addresses)
    err = assert_raises(ArgumentError) { v.var(:nonexistent) }
    assert_match(/nonexistent/, err.message)
  end

  def test_reading_a_variable_without_a_map_is_a_friendly_error
    rom, = computed_rom
    v = assert_emulator_loads_rom(rom, frames: 2) # no vars: given
    err = assert_raises(ArgumentError) { v.var(:answer) }
    assert_match(/var_addresses/, err.message)
  end

  # --- a count that went below nothing ---
  #
  # A whole number in a program here is signed, and a game counts below nothing all the time:
  # a timer run past zero, a contact record set to minus one meaning "not hurt and not counting".
  # A word in memory has no sign in it, so a reader handing the word straight back says four
  # billion where the program says minus one — and nothing about that reads as wrong. The test
  # a game writes for it (`count > 0` is false while it is minus one) then passes while saying
  # the opposite of what it means.

  # Two counts taken below nothing by the program itself, rather than merely declared there.
  def counted_below_nothing
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      var :hurt, 2
      sub! :hurt, 3
      var :cold, 0
      sub! :cold, 40
      halt
    end
    builder.emit_pending_functions
    builder.program
  end

  def below_nothing_on_the_console
    program = counted_below_nothing
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "BELOW", code: "BNEG", maker: "01")
    [program, backend, assert_emulator_loads_rom(rom, frames: 3, vars: backend.var_addresses)]
  end

  def test_a_variable_counted_below_nothing_reads_back_below_nothing
    _program, _backend, v = below_nothing_on_the_console

    assert_equal(-1, v.var(:hurt), "the number the program counted to, not the word holding it")
    assert_equal(-40, v.var(:cold))
  end

  # The reason it matters, rather than merely being tidier: a game checks the cartridge against
  # the oracle, and two backends answering the same question with two numbers fails for a reason
  # that has nothing to do with the game.
  def test_the_two_backends_read_a_negative_variable_the_same_way
    program, _backend, console = below_nothing_on_the_console
    oracle = Reference.new.run(program)

    assert_equal(-1, oracle[:hurt], "the oracle counted below nothing, as the program says")
    assert_equal oracle[:hurt], console.var(:hurt)
    assert_equal oracle[:cold], console.var(:cold)
  end

  # And the raw read is still the raw word, which is what makes the two worth having separately:
  # a variable is a whole number in a program, an address is whatever is sitting at it.
  def test_reading_the_same_place_as_a_raw_address_is_still_the_word
    _program, backend, v = below_nothing_on_the_console

    assert_equal 0xFFFF_FFFF, v.mem32(backend.var_addresses.fetch(:hurt))
  end
end
