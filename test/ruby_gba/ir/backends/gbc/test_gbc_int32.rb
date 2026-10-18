# frozen_string_literal: true

require "test_helper"

# The Game Boy Color's arithmetic (GBC::Runtime::Int32, written in SM83) gives the answer IR::Int32
# gives, for the values where an 8-bit processor carrying from byte to byte is most likely to get it
# wrong: the ends of the range, either side of nought, powers of two and the bytes' edges, shift
# counts on and past the edge, and products and fractions at full width — every pair of them, plus a
# spread of random ones. Int32 is the answer key; a comparison is answered the way the interpreter
# answers it.
#
# The routines run on the console itself, in the emulator: a small cartridge waits for a batch of
# sums written into its work memory, works them out and says it has, and the batch's answers are
# read back.
class TestGBCInt32 < Minitest::Test
  Int32 = RubyGBA::IR::Int32
  GBC = RubyGBA::IR::Backends::GBC
  H = RubyGBA::Console::GBCHardware

  EDGES = [
    0, 1, -1, 2, -2, 3, -7, 7, 64, -64, 127, 128, -128, -129, 255, 256, 257, -255, -256,
    0x7FFF, 0x8000, -0x8000, 0xFFFF, 0x1_0000, -0x1_0000, 0xFF_FFFF, 0x100_0000, 98_304, -98_304,
    1 << 30, -(1 << 30), Int32::MAX, Int32::MAX - 1, Int32::MIN, Int32::MIN + 1
  ].freeze
  RANDOM = Random.new(20_261_018).then { |r| Array.new(24) { Int32.wrap(r.rand(-(2**40)..(2**40))) } }.freeze
  VALUES = (EDGES + RANDOM).freeze
  SHIFTS = [-33, -1, 0, 1, 4, 7, 8, 9, 15, 16, 24, 31, 32, 33, 64, 256, 257].freeze
  FRACTION_BITS = [0, 1, 8, 12, 16, 31, 32].freeze

  # Each sum the cartridge knows, by the number the host writes for it.
  OPS = %w[add sub mul div mod bit_and bit_or bit_xor shift_left shift_right neg bit_not abs
           lt le gt ge eq ne both either mul_fix div_fix].freeze

  # The cartridge's work memory: whether a batch is waiting (1) or done (2), how many sums it
  # holds, and the sums: each the op, a, b and c, and a word for the answer.
  FLAG = 0xC100
  COUNT = 0xC101
  CASES = 0xC104
  CASE_BYTES = 20
  BATCH = 128

  def self.expected(name, a, b, c)
    case name
    when "neg", "bit_not" then Int32.public_send(name, a)
    when "abs" then a.negative? ? Int32.neg(a) : a
    when "mul_fix", "div_fix" then Int32.public_send(name, a, b, c)
    when "lt" then Int32.cmp(a, b) < 0 ? 1 : 0
    when "le" then Int32.cmp(a, b) <= 0 ? 1 : 0
    when "gt" then Int32.cmp(a, b) > 0 ? 1 : 0
    when "ge" then Int32.cmp(a, b) >= 0 ? 1 : 0
    when "eq" then Int32.cmp(a, b).zero? ? 1 : 0
    when "ne" then Int32.cmp(a, b).zero? ? 0 : 1
    when "both" then !a.zero? && !b.zero? ? 1 : 0
    when "either" then !a.zero? || !b.zero? ? 1 : 0
    else Int32.public_send(name, a, b)
    end
  end

  def self.cases
    pairs = VALUES.product(VALUES)
    two = %w[add sub mul bit_and bit_or bit_xor lt le gt ge eq ne both either div mod].product(pairs)
    one = %w[neg abs bit_not].product(VALUES.map { |a| [a, 0] })
    shifting = %w[shift_left shift_right].product(VALUES.product(SHIFTS))
    fractions = %w[mul_fix div_fix].product(EDGES.product(EDGES.first(20), FRACTION_BITS).map { |a, b, c| [a, b, c] })
    (two + one + shifting).map { |name, (a, b)| [name, a, b, 0] } + fractions.map { |name, (a, b, c)| [name, a, b, c] }
  end

  def test_every_sum_matches_int32
    wrong = []
    with_cartridge do |core|
      self.class.cases.each_slice(BATCH) do |batch|
        answers(core, batch).zip(batch).each do |got, (name, a, b, c)|
          want = self.class.expected(name, a, b, c)
          wrong << "#{name}(#{a}, #{b}#{", #{c}" if c.nonzero?}) gave #{got}, not #{want}" unless got == want
        end
      end
    end
    assert_empty wrong.first(30), "#{wrong.size} sums were wrong; the first of them are listed"
  end

  private

  # Until the cartridge says it is ready: it clears its memory as it starts, a batch written before
  # that would be lost.
  def wait_for_cartridge(core)
    frames = 0
    until core.bus_read8(FLAG) == 2
      core.run_frame
      frames += 1
      flunk "the cartridge did not start in 60 frames" if frames > 60
    end
  end

  def answers(core, batch)
    batch.each_with_index do |(name, a, b, c), i|
      at = CASES + (i * CASE_BYTES)
      core.bus_write32(at, OPS.index(name))
      [a, b, c].each_with_index { |value, k| core.bus_write32(at + 4 + (k * 4), value & 0xFFFF_FFFF) }
    end
    core.bus_write32(FLAG, 1 | (batch.size << 8))
    frames = 0
    loop do
      core.run_frame
      frames += 1
      break if core.bus_read8(FLAG) == 2

      flunk "the cartridge did not finish a batch in 600 frames" if frames > 600
    end
    batch.each_index.map { |i| Int32.wrap(core.bus_read32(CASES + (i * CASE_BYTES) + 16)) }
  end

  def with_cartridge
    Dir.mktmpdir do |dir|
      path = File.join(dir, "int32.gbc")
      File.binwrite(path, cartridge)
      core = RubyGBAEmulator::Core.new(path, dir, nil)
      wait_for_cartridge(core)
      yield core
    ensure
      core&.destroy
    end
  end

  # A cartridge with the runtime and a loop that works out each waiting batch.
  def cartridge
    memory = GBC::Memory.new
    asm = GBC::SM83.new("harness", home: :fixed)
    GBC::Runtime::Boot.emit(asm, main: "main")
    GBC::Runtime::Boot.emit_display_off(asm)
    GBC::Runtime::Boot.emit_clear(asm)
    GBC::Runtime::Int32.emit(asm, memory)
    asm.label("rt_start")
    asm.ret
    asm.label("rt_vblank_interrupt")
    asm.reti
    asm.label("rg_halt")
    asm.halt
    asm.jump_relative("rg_halt")
    pointer = memory.quick(2)
    count = memory.quick(1)
    asm.label("main")
    asm.load(:a, 2) # ready for a batch
    asm.load([FLAG], :a)
    asm.label("wait")
    asm.load(:a, [FLAG])
    asm.cp_a(1)
    asm.jump_relative(:nz, "wait")
    asm.load(:a, [COUNT])
    asm.load_high(count, :a)
    asm.load(:hl, CASES)
    asm.label("next")
    asm.load(:a, :l)
    asm.load_high(pointer, :a)
    asm.load(:a, :h)
    asm.load_high(pointer + 1, :a)
    asm.load(:a, [:hl])
    4.times { asm.inc(:hl) }
    asm.push(:af)
    %i[e d c b].each do |reg|
      asm.load(:a, [:hli])
      asm.load(reg, :a)
    end
    asm.pop(:af)
    asm.call("dispatch")
    asm.load_high(:a, pointer)
    asm.load(:l, :a)
    asm.load_high(:a, pointer + 1)
    asm.load(:h, :a)
    16.times { asm.inc(:hl) }
    %i[e d c b].each do |reg|
      asm.load(:a, reg)
      asm.load([:hli], :a)
    end
    asm.load_high(:a, count)
    asm.dec(:a)
    asm.load_high(count, :a)
    asm.jump_relative(:nz, "next")
    asm.load(:a, 2)
    asm.load([FLAG], :a)
    asm.jump("wait")
    emit_dispatch(asm)
    sections = [*GBC::Runtime::Boot.vector_sections, asm.section]
    linked = GBC::Linker.new(sections, fixed_from: H::HEADER_END).link
    RubyGBA::Cartridge::GBCROM.new(linked.banks, title: "INT32").bytes
  end

  # A = the op, BCDE = a, HL = b (and c after it): the answer in BCDE.
  def emit_dispatch(asm)
    asm.label("dispatch")
    OPS.each_with_index do |name, number|
      asm.cp_a(number)
      asm.jump(:z, "op_#{name}")
    end
    asm.ret
    { "add" => "rt_add32", "sub" => "rt_sub32", "mul" => "rt_mul32", "div" => "rt_div32", "mod" => "rt_mod32",
      "bit_and" => "rt_and32", "bit_or" => "rt_or32", "bit_xor" => "rt_xor32", "shift_left" => "rt_shl32",
      "shift_right" => "rt_shr32", "neg" => "rt_neg32", "bit_not" => "rt_not32", "abs" => "rt_abs32",
      "both" => "rt_both32", "either" => "rt_either32", "mul_fix" => "rt_mul_fix", "div_fix" => "rt_div_fix" }
      .each do |name, routine|
        asm.label("op_#{name}")
        asm.jump(routine)
      end
    { "lt" => [1, "rt_bool_of_z"], "le" => [2, "rt_bool_of_nz"], "gt" => [2, "rt_bool_of_z"],
      "ge" => [1, "rt_bool_of_nz"], "eq" => [0, "rt_bool_of_z"], "ne" => [0, "rt_bool_of_nz"] }.each do |name, (k, bool)|
      asm.label("op_#{name}")
      asm.call("rt_cmp32")
      asm.cp_a(k)
      asm.jump(bool)
    end
  end
end
