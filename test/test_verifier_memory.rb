# frozen_string_literal: true

require "test_helper"

# Reading run-time state back off real hardware. gemba reads the GBA bus directly,
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
      set :answer, ANSWER
      set :doubled, 0
      add :doubled, :answer
      add :doubled, :answer # doubled = 2 * answer
      halt
    end
    builder.emit_pending_functions
    backend = GBA.new
    bytes = backend.lower(builder.program)
    [ROM.assemble(bytes, title: "MEMTEST", code: "BMEM", maker: "01"), backend]
  end

  def test_reads_a_variable_by_name_on_hardware
    rom, backend = computed_rom
    v = assert_gemba_loads_rom(rom, frames: 3, vars: backend.var_addresses)
    assert_equal ANSWER, v.var(:answer), "the ROM's :answer wasn't read back from IWRAM"
    assert_equal ANSWER * 2, v.var(:doubled), "the computed :doubled wasn't read back"
  end

  def test_reads_memory_by_raw_address
    rom, backend = computed_rom
    v = assert_gemba_loads_rom(rom, frames: 3, vars: backend.var_addresses)
    assert_equal ANSWER, v.mem32(backend.var_addresses.fetch(:answer))
  end

  def test_reads_the_vcount_register
    rom, backend = computed_rom
    v = assert_gemba_loads_rom(rom, frames: 3, vars: backend.var_addresses)
    # VCOUNT (0x04000006) is the scanline being drawn — a frame boundary sits in vblank.
    assert_includes 0..227, v.mem16(0x0400_0006), "VCOUNT should be a scanline number"
  end

  def test_an_unknown_variable_is_a_friendly_error
    rom, backend = computed_rom
    v = assert_gemba_loads_rom(rom, frames: 2, vars: backend.var_addresses)
    err = assert_raises(ArgumentError) { v.var(:nonexistent) }
    assert_match(/nonexistent/, err.message)
  end

  def test_reading_a_variable_without_a_map_is_a_friendly_error
    rom, = computed_rom
    v = assert_gemba_loads_rom(rom, frames: 2) # no vars: given
    err = assert_raises(ArgumentError) { v.var(:answer) }
    assert_match(/var_addresses/, err.message)
  end
end
