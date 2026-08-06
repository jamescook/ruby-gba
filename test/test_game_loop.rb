# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Frame timing lowers `wait_vblank` to the BIOS routine VBlankIntrWait (SWI 0x05):
# the CPU sleeps until the next VBlank interrupt instead of busy-polling the scanline
# counter. That needs interrupts armed at boot and a small handler that acknowledges
# each one — get the acknowledge wrong and the interrupt re-fires forever, so the
# real proof is the differential test at the bottom: the loop advances exactly once
# per frame on the interpreter AND on real hardware (a hang would miss the count).
class TestGameLoop < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  GBA = RubyGBA::IR::Backends::GBA
  Reference = RubyGBA::IR::Backends::Reference

  # ARM SWI with comment 0x05 in the top byte -> VBlankIntrWait.
  VBLANK_INTR_WAIT = 0xEF000000 | (0x05 << 16)

  def build(validate: false, &block)
    RubyGBA.build("LOOPTEST", code: "BLPT", maker: "01", validate: validate, &block)
  end

  # Lower a DSL program built in +block+ and return the backend (for its label table)
  # alongside the raw code bytes.
  def lower(&block)
    builder = RubyGBA::Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    backend = GBA.new
    code = backend.lower(builder.program)
    [backend, code]
  end

  # All ARM words in the ROM's code region, up to the zero padding.
  def instructions(rom)
    result = []
    offset = RubyGBA::ROM::ENTRY_OFFSET
    while offset + 4 <= rom.buffer.bytesize
      word = rom.buffer[offset, 4].unpack1("V")
      break if word.zero?

      result << word
      offset += 4
    end
    result
  end

  # ========================================================================
  # wait_vblank lowering
  # ========================================================================

  def test_wait_vblank_sleeps_on_the_vblank_interrupt
    rom = build do
      wait_vblank
      halt
    end
    assert_includes instructions(rom), VBLANK_INTR_WAIT,
                    "wait_vblank should call VBlankIntrWait (SWI 0x05), not busy-wait"
  end

  def test_wait_vblank_no_longer_busy_polls_the_scanline
    rom = build do
      wait_vblank
      halt
    end
    assert_equal 0, instructions(rom).count { |i| cmp_imm_160?(i) },
                 "the old scanline busy-wait (CMP #160) should be gone"
  end

  def test_the_interrupt_handler_is_emitted
    backend, = lower { game_loop { wait_vblank } }
    assert backend.labels.key?(GBA::IRQ_HANDLER_LABEL),
           "a VBlank interrupt handler routine is emitted for the vector to point at"
  end

  # The handler must acknowledge in two places or VBlankIntrWait never wakes: the
  # hardware flag register and the BIOS's own copy. Both are 16-bit stores, and the
  # handler is the only place that returns with BX LR.
  def test_the_handler_acknowledges_and_returns
    _backend, code = lower { game_loop { wait_vblank } }
    words = code.unpack("V*")
    assert_includes words, 0xE12FFF1E, "the handler returns to the BIOS with BX LR"
    stored = store_halfword_targets(words)
    assert_includes stored, REG_IF,     "the handler acknowledges the hardware flag (REG_IF)"
    assert_includes stored, REG_IFBIOS, "the handler acknowledges the BIOS flag copy (REG_IFBIOS)"
  end

  # A program that never waits for a frame needs none of the interrupt machinery.
  def test_a_program_without_wait_vblank_arms_no_interrupts
    backend, code = lower { pixel 0, 0, :red }
    refute backend.labels.key?(GBA::IRQ_HANDLER_LABEL), "no handler when nothing waits"
    refute_includes code.unpack("V*"), VBLANK_INTR_WAIT, "no VBlankIntrWait when nothing waits"
  end

  # ========================================================================
  # game_loop
  # ========================================================================

  def test_game_loop_branches_back_to_the_wait
    rom = build { game_loop {} }
    insts = instructions(rom)

    top = insts.index(VBLANK_INTR_WAIT) # the loop body starts at the wait
    branch_idx = insts.rindex { |i| branch?(i) && unconditional?(i) }
    refute_nil branch_idx, "the loop ends in an unconditional branch"

    offset = insts[branch_idx] & 0x00FFFFFF
    signed = (offset & 0x800000).zero? ? offset : offset - 0x1000000
    assert_operator signed, :<, 0, "the loop branch goes backward"
    assert_equal top, branch_idx + 2 + signed, "it branches back to the top of the loop"
  end

  def test_game_loop_with_setup_before_it_still_loops
    rom = build do
      screen :bitmap
      set :counter, 0
      game_loop do
        add_var :counter, 1
      end
    end
    insts = instructions(rom)
    assert insts.any? { |i| branch?(i) && unconditional?(i) }, "there is a loop back-branch"
  end

  # ========================================================================
  # Behavior: one iteration per frame, agreeing on both backends
  # ========================================================================

  # Count up once per frame, capped at +count+ so the value settles. Reading it back
  # after enough frames tells us the loop really advanced (and didn't hang) — the same
  # program, the same final value, whether interpreted or run on hardware.
  def counting_loop(count)
    builder = RubyGBA::Builder.new
    builder.instance_eval do
      screen :bitmap
      frames = var :frames, 0
      game_loop do
        (frames < count).then { add :frames, 1 }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_the_loop_advances_once_per_frame_on_the_interpreter
    program = counting_loop(20)
    i = Reference.new.run(program, max_steps: 100_000)
    assert_equal 20, i[:frames], "the loop bumps the counter once per frame up to the cap"
  end

  def test_the_loop_advances_once_per_frame_on_the_console
    program = counting_loop(20)
    backend = GBA.new
    rom = RubyGBA::ROM.assemble(backend.lower(program), title: "FRAMES", code: "BFRM", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 30, vars: backend.var_addresses)
    assert_equal 20, v.var(:frames),
                 "VBlank interrupts advance the loop once per frame on hardware — no interrupt hang"
  end

  def test_game_loop_runs_in_mgba
    rom = build do
      screen :bitmap
      set :counter, 0
      game_loop do
        add_var :counter, 1
      end
    end
    assert_gemba_loads_rom(rom, frames: 10)
  end

  private

  # STRH src, [addr] stores from a register; find the immediate addresses those
  # stores target by tracking the most recent value loaded into each base register
  # (load_immediate is MOV then ORRs). Enough to confirm the handler's two acks.
  def store_halfword_targets(words)
    regs = Hash.new(0)
    targets = []
    words.each do |w|
      if mov_imm?(w)
        regs[dest(w)] = rotated(w)
      elsif orr_imm?(w)
        regs[dest(w)] |= rotated(w)
      elsif strh?(w)
        targets << regs[(w >> 16) & 0xF]
      end
    end
    targets
  end

  def mov_imm?(w) = (w & 0x0FFF0000) == 0x03A00000
  def orr_imm?(w) = (w & 0x0FE00000) == 0x03800000
  def strh?(w) = (w & 0x0E1000F0) == 0x000000B0
  def dest(w) = (w >> 12) & 0xF
  def rotated(w) = rotate_right(w & 0xFF, ((w >> 8) & 0xF) * 2)

  def rotate_right(value, amount)
    amount &= 31
    return value if amount.zero?

    ((value >> amount) | (value << (32 - amount))) & 0xFFFFFFFF
  end

  def cmp_imm_160?(inst)
    return false unless ((inst >> 21) & 0xF) == 0xA && ((inst >> 20) & 1) == 1 && ((inst >> 25) & 1) == 1

    rotate_right(inst & 0xFF, ((inst >> 8) & 0xF) * 2) == 160
  end

  def branch?(inst) = (inst & 0x0E000000) == 0x0A000000
  def unconditional?(inst) = ((inst >> 28) & 0xF) == 0xE
end
