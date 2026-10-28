# frozen_string_literal: true

require "test_helper"

# The Super Nintendo's arithmetic (SNES::Runtime::Int32, written in 65816) gives the answer
# IR::Int32 gives, for the values where carrying from half to half is most likely to go wrong: the
# ends of the range, either side of nought, powers of two and the halves' edges, shift counts on and
# past the edge, and products and fractions at full width — every pair of them, plus a spread of
# random ones. Int32 is the answer key.
#
# The routines run on the console itself, in the emulator: a small cartridge waits for a batch of
# sums written into its work RAM, works them out and says it has, and the batch's answers are read
# back.
class TestSNESInt32 < Minitest::Test
  Int32 = VBlank::IR::Int32
  SNES = VBlank::IR::Backends::SNES

  EDGES = [
    0, 1, -1, 2, -2, 3, -7, 7, 64, -64, 127, 128, -128, -129, 255, 256, 257, -255, -256,
    0x7FFF, 0x8000, -0x8000, 0xFFFF, 0x1_0000, -0x1_0000, 0xFF_FFFF, 0x100_0000, 98_304, -98_304,
    1 << 30, -(1 << 30), Int32::MAX, Int32::MAX - 1, Int32::MIN, Int32::MIN + 1
  ].freeze
  RANDOM = Random.new(20_261_028).then { |r| Array.new(16) { Int32.wrap(r.rand(-(2**40)..(2**40))) } }.freeze
  VALUES = (EDGES + RANDOM).freeze
  SHIFTS = [-33, -1, 0, 1, 4, 7, 8, 9, 15, 16, 17, 24, 31, 32, 33, 64, 256, 65_536].freeze
  FRACTION_BITS = [0, 1, 8, 12, 15, 16, 17, 31, 32].freeze

  # Each routine the cartridge knows, by the number the host writes for it.
  OPS = { "mul" => "rt_mul32", "div" => "rt_div32", "mod" => "rt_mod32", "shift_left" => "rt_shl32",
          "shift_right" => "rt_shr32", "mul_fix" => "rt_mul_fix", "div_fix" => "rt_div_fix" }.freeze

  # The cartridge's work RAM: whether a batch is waiting (1) or done (2), how many sums it holds,
  # and the sums: each the op, a, b and c, and the answer.
  FLAG = 0x1000
  COUNT = 0x1002
  CASES = 0x1004
  CASE_BYTES = 18
  BATCH = 128

  def self.cases
    pairs = VALUES.product(VALUES)
    two = %w[mul div mod].product(pairs).map { |name, (a, b)| [name, a, b, 0] }
    shifting = %w[shift_left shift_right].product(VALUES.product(SHIFTS)).map { |name, (a, b)| [name, a, b, 0] }
    fractions = %w[mul_fix div_fix].product(EDGES.product(EDGES.first(24), FRACTION_BITS))
                                   .map { |name, (a, b, c)| [name, a, b, c] }
    two + shifting + fractions
  end

  def test_every_sum_matches_int32
    wrong = []
    with_cartridge do |core|
      self.class.cases.each_slice(BATCH) do |batch|
        answers(core, batch).zip(batch).each do |got, (name, a, b, c)|
          want = Int32.public_send(name, *[a, b, c].first(name.end_with?("fix") ? 3 : 2))
          wrong << "#{name}(#{a}, #{b}#{", #{c}" if c.nonzero?}) gave #{got}, not #{want}" unless got == want
        end
      end
    end
    assert_empty wrong.first(30), "#{wrong.size} sums were wrong; the first of them are listed"
  end

  private def answers(core, batch)
    batch.each_with_index do |(name, a, b, c), i|
      at = CASES + (i * CASE_BYTES)
      bytes = [OPS.keys.index(name), a & 0xFFFF_FFFF, b & 0xFFFF_FFFF, c & 0xFFFF_FFFF].pack("vV3")
      bytes.bytes.each_with_index { |byte, j| core.wram_write8(at + j, byte) }
    end
    core.wram_write8(COUNT, batch.size)
    core.wram_write8(COUNT + 1, 0)
    core.wram_write8(FLAG, 1)
    frames = 0
    until core.wram_read8(FLAG) == 2
      core.run_frame
      frames += 1
      flunk "the cartridge did not finish a batch in 600 frames" if frames > 600
    end
    Array.new(batch.size) { |i| Int32.wrap(core.wram_read32(CASES + (i * CASE_BYTES) + 14)) }
  end

  private def with_cartridge
    Dir.mktmpdir do |dir|
      path = File.join(dir, "int32.sfc")
      cartridge.write(path)
      core = VBlank::Diagnostics::Emulator.open_snes(path)
      2.times { core.run_frame } # booted: boot clears all of work RAM
      yield core
    ensure
      core&.destroy
    end
  end

  # The runtime's boot and arithmetic, and a main routine that works out each batch: for each sum,
  # its numbers into R0, R1 and R2, the routine its op names, and R0 back into the batch.
  private def cartridge
    r = SNES::Memory
    vectors = SNES::W65816.new("vectors", home: :first)
    SNES::Runtime::Boot.emit_vectors(vectors)
    asm = SNES::W65816.new("runtime")
    SNES::Runtime::Boot.emit(asm, main: "test_main")
    SNES::Runtime::Boot.emit_zero(asm)
    SNES::Runtime::Int32.emit(asm, SNES::Runtime::Int32.scratch(SNES::Memory.new))
    asm.instance_eval do
      %w[rt_start rt_halt rt_vblank_interrupt].each do |name|
        label name
        name == "rt_vblank_interrupt" ? rti : rtl
      end
      label "test_main"
      label "test_wait"
      lda abs(FLAG)
      and_a 0xFF
      cmp 1
      bne "test_wait"
      ldx 0
      label "test_case"
      phx
      lda abs_x(CASES + 2)
      sta dp(r.register(0))
      lda abs_x(CASES + 4)
      sta dp(r.register(0) + 2)
      lda abs_x(CASES + 6)
      sta dp(r.register(1))
      lda abs_x(CASES + 8)
      sta dp(r.register(1) + 2)
      lda abs_x(CASES + 10)
      sta dp(r.register(2))
      lda abs_x(CASES + 12)
      sta dp(r.register(2) + 2)
      lda abs_x(CASES)
      OPS.values.each_with_index do |routine, number|
        cmp number
        bne "test_not_#{number}"
        jsl long(routine)
        bra "test_done"
        label "test_not_#{number}"
      end
      label "test_done"
      plx
      lda dp(r.register(0))
      sta abs_x(CASES + 14)
      lda dp(r.register(0) + 2)
      sta abs_x(CASES + 16)
      txa
      clc
      adc CASE_BYTES
      tax
      dec abs(COUNT)
      branch_long :bne, "test_case"
      sep 0x20
      lda 2
      sta abs(FLAG)
      rep 0x20
      brl "test_wait"
    end
    linked = SNES::Linker.new([vectors.section, asm.section]).link
    VBlank::Cartridge::SNESROM.new(linked.banks, title: "INT32",
                                                 vectors: { reset: linked.address_of("rt_reset") & 0xFFFF,
                                                            nmi: linked.address_of("rt_nmi") & 0xFFFF })
  end
end
