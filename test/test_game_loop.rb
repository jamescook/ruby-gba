# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

class TestGameLoop < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  def build(doctor: false, &block)
    RubyGBA.build("LOOPTEST", code: "BLPT", maker: "01", doctor: doctor, &block)
  end

  # Helper: extract all instructions from code region
  def instructions(rom)
    start = RubyGBA::ROM::ENTRY_OFFSET
    result = []
    offset = start
    while offset + 4 <= rom.buffer.bytesize
      word = rom.buffer[offset, 4].unpack1("V")
      break if word == 0  # stop at zero padding
      result << word
      offset += 4
    end
    result
  end

  # ========================================================================
  # wait_vblank
  # ========================================================================

  def test_wait_vblank_emits_instructions
    rom = build do
      wait_vblank
      halt
    end

    insts = instructions(rom)
    # Should have: load_immediate (1-2 insts) + 6 loop insts + halt = ~8-9
    assert_operator insts.size, :>=, 8
  end

  def test_wait_vblank_loads_reg_vcount_address
    rom = build do
      wait_vblank
      halt
    end

    insts = instructions(rom)
    # First instruction(s) load REG_VCOUNT (0x04000006) into r0
    # Decode the load_immediate sequence
    value = decode_load_sequence(insts)
    assert_equal REG_VCOUNT, value, "should load REG_VCOUNT address"
  end

  def test_wait_vblank_has_ldrh_instructions
    rom = build do
      wait_vblank
      halt
    end

    insts = instructions(rom)
    # Should have at least 2 LDRH instructions (one per phase)
    ldrh_count = insts.count { |i| ldrh?(i) }
    assert_equal 2, ldrh_count, "expected 2 LDRH instructions (one per phase)"
  end

  def test_wait_vblank_has_cmp_160
    rom = build do
      wait_vblank
      halt
    end

    insts = instructions(rom)
    # Should have at least 2 CMP #160 instructions
    cmp_count = insts.count { |i| cmp_imm_160?(i) }
    assert_equal 2, cmp_count, "expected 2 CMP #160 instructions"
  end

  def test_wait_vblank_has_conditional_branches
    rom = build do
      wait_vblank
      halt
    end

    insts = instructions(rom)
    # Phase 1: BGE (cond = 0xA), Phase 2: BLT (cond = 0xB)
    conds = insts.select { |i| branch?(i) && !unconditional?(i) }
                 .map { |i| (i >> 28) & 0xF }
    assert_includes conds, 0xA, "expected BGE branch"
    assert_includes conds, 0xB, "expected BLT branch"
  end

  # ========================================================================
  # game_loop
  # ========================================================================

  def test_game_loop_emits_backward_branch
    rom = build do
      game_loop do
        wait_vblank
      end
    end

    insts = instructions(rom)
    # Last instruction should be an unconditional branch backward
    last = insts.last
    assert unconditional?(last), "last instruction should be unconditional branch"
    assert branch?(last), "last instruction should be a branch"

    # The offset should be negative (backward)
    offset = last & 0x00FFFFFF
    # Sign-extend 24-bit to check it's negative
    signed = (offset & 0x800000) != 0 ? offset - 0x1000000 : offset
    assert_operator signed, :<, 0, "branch should be backward"
  end

  def test_game_loop_branch_targets_start
    rom = build do
      game_loop do
        wait_vblank
      end
    end

    insts = instructions(rom)
    last_idx = insts.size - 1
    last = insts[last_idx]

    # Decode branch offset (signed 24-bit, in words, relative to PC+8)
    offset = last & 0x00FFFFFF
    signed = (offset & 0x800000) != 0 ? offset - 0x1000000 : offset
    # Target = current_position + 2 + offset (PC is 2 words ahead)
    target_idx = last_idx + 2 + signed
    assert_equal 0, target_idx, "branch should target the first instruction"
  end

  def test_game_loop_with_code_before
    rom = build do
      display :bitmap
      set :counter, 0
      game_loop do
        wait_vblank
        add_var :counter, 1
      end
    end

    insts = instructions(rom)
    # Should have display setup + var init + loop body + backward branch
    assert_operator insts.size, :>, 10

    # Last instruction is backward branch
    last = insts.last
    assert unconditional?(last), "last instruction should be unconditional branch"
    assert branch?(last), "last instruction should be a branch"
  end

  def test_game_loop_runs_in_mgba
    rom = build do
      display :bitmap
      set :counter, 0
      game_loop do
        wait_vblank
        add_var :counter, 1
      end
    end

    assert_gemba_loads_rom(rom, frames: 10)
  end

  private

  # Decode a load_immediate sequence at the start of instructions
  def decode_load_sequence(insts)
    result = 0
    insts.each do |inst|
      opcode = (inst >> 21) & 0xF
      case opcode
      when 0xD  # MOV
        imm8 = inst & 0xFF
        rot = ((inst >> 8) & 0xF) * 2
        result = rotate_right(imm8, rot)
      when 0xC  # ORR
        imm8 = inst & 0xFF
        rot = ((inst >> 8) & 0xF) * 2
        result |= rotate_right(imm8, rot)
      else
        break  # not part of load sequence
      end
    end
    result
  end

  def rotate_right(value, amount)
    amount &= 31
    return value if amount == 0
    ((value >> amount) | (value << (32 - amount))) & 0xFFFFFFFF
  end

  def ldrh?(inst)
    # LDRH: bits 27:25 = 000, bit 20 = 1, bits 7:4 = 1011
    (inst & 0x0E0000F0) == 0x000000B0 && ((inst >> 20) & 1) == 1
  end

  # Returns true if the instruction is "CMP rn, #160" — the scanline
  # check used by wait_vblank to detect line 160 (start of VBlank).
  def cmp_imm_160?(inst)
    opcode = (inst >> 21) & 0xF
    s_bit = (inst >> 20) & 1
    i_bit = (inst >> 25) & 1
    return false unless opcode == 0xA && s_bit == 1 && i_bit == 1

    imm8 = inst & 0xFF
    rot = ((inst >> 8) & 0xF) * 2
    value = rotate_right(imm8, rot)
    value == 160
  end

  def branch?(inst)
    # Branch: bits 27:25 = 101
    (inst & 0x0E000000) == 0x0A000000
  end

  def unconditional?(inst)
    ((inst >> 28) & 0xF) == 0xE
  end
end
