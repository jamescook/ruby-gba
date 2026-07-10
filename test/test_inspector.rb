# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

class TestInspector < Minitest::Test
  # Helper: disassemble a single instruction word via Inspector internals.
  def disasm(word)
    inspector = RubyGBA::Inspector.from_rom(minimal_rom)
    desc, = inspector.send(:disassemble, word, Array.new(16, 0))
    desc
  end

  def minimal_rom
    RubyGBA.build("TEST", code: "BTST", maker: "01", doctor: false) do
      halt
    end
  end

  # ========================================================================
  # Special instructions
  # ========================================================================

  def test_halt
    assert_includes disasm(0xEAFFFFFE), "HALT"
  end

  def test_nop
    assert_includes disasm(0xE1A00000), "NOP"
  end

  # ========================================================================
  # PUSH / POP
  # ========================================================================

  def test_push_lr
    result = disasm(0xE92D4000)
    assert_includes result, "PUSH"
    assert_includes result, "lr"
  end

  def test_pop_pc
    result = disasm(0xE8BD8000)
    assert_includes result, "POP"
    assert_includes result, "pc"
  end

  def test_push_multiple
    # PUSH {r0, r1, lr}
    result = disasm(0xE92D4003)
    assert_includes result, "PUSH"
    assert_includes result, "r0"
    assert_includes result, "r1"
    assert_includes result, "lr"
  end

  # ========================================================================
  # Branches
  # ========================================================================

  def test_branch_unconditional
    word = RubyGBA::ASM.branch(-10).unpack1("V")
    result = disasm(word)
    assert_includes result, "B"
    refute_includes result, "???"
  end

  def test_branch_conditional_ge
    word = RubyGBA::ASM.branch_cond(:ge, 4).unpack1("V")
    result = disasm(word)
    assert_includes result, "BGE"
  end

  def test_branch_conditional_lt
    word = RubyGBA::ASM.branch_cond(:lt, -2).unpack1("V")
    result = disasm(word)
    assert_includes result, "BLT"
  end

  def test_branch_conditional_eq
    word = RubyGBA::ASM.branch_cond(:eq, 3).unpack1("V")
    result = disasm(word)
    assert_includes result, "BEQ"
  end

  def test_branch_conditional_ne
    word = RubyGBA::ASM.branch_cond(:ne, 5).unpack1("V")
    result = disasm(word)
    assert_includes result, "BNE"
  end

  def test_branch_conditional_gt
    word = RubyGBA::ASM.branch_cond(:gt, 2).unpack1("V")
    result = disasm(word)
    assert_includes result, "BGT"
  end

  def test_branch_conditional_le
    word = RubyGBA::ASM.branch_cond(:le, 2).unpack1("V")
    result = disasm(word)
    assert_includes result, "BLE"
  end

  def test_branch_link
    word = RubyGBA::ASM.branch_link(10).unpack1("V")
    result = disasm(word)
    assert_includes result, "BL"
  end

  def test_bx_lr
    result = disasm(0xE12FFF1E)
    assert_includes result, "BX"
    assert_includes result, "lr"
  end

  # ========================================================================
  # Data processing — immediate
  # ========================================================================

  def test_mov_imm
    word = RubyGBA::ASM.load_immediate(3, 42).unpack1("V")
    result = disasm(word)
    assert_includes result, "MOV"
    assert_includes result, "r3"
  end

  def test_add_imm
    word = RubyGBA::ASM.add_imm(10, 10, 12).unpack1("V")
    result = disasm(word)
    assert_includes result, "ADD"
    assert_includes result, "r10"
    assert_includes result, "0xc"
  end

  def test_sub_imm
    word = RubyGBA::ASM.sub_imm(10, 10, 1).unpack1("V")
    result = disasm(word)
    assert_includes result, "SUB"
    assert_includes result, "r10"
  end

  def test_cmp_imm
    word = RubyGBA::ASM.cmp_imm(10, 0).unpack1("V")
    result = disasm(word)
    assert_includes result, "CMP"
    assert_includes result, "r10"
  end

  def test_tst_imm
    word = RubyGBA::ASM.tst_imm(8, 8).unpack1("V")
    result = disasm(word)
    assert_includes result, "TST"
    assert_includes result, "r8"
  end

  def test_rsb_imm
    word = RubyGBA::ASM.rsb_imm(10, 10, 0).unpack1("V")
    result = disasm(word)
    assert_includes result, "RSB"
    assert_includes result, "r10"
  end

  def test_and_imm
    word = RubyGBA::ASM.and_imm(8, 8, 0xFF).unpack1("V")
    result = disasm(word)
    assert_includes result, "AND"
  end

  def test_orr_imm
    word = RubyGBA::ASM.orr_imm(0, 0, 0x400).unpack1("V")
    result = disasm(word)
    assert_includes result, "ORR"
  end

  def test_mvn_imm
    word = RubyGBA::ASM.mvn_imm(0, 0).unpack1("V")
    result = disasm(word)
    assert_includes result, "MVN"
  end

  # ========================================================================
  # Data processing — register
  # ========================================================================

  def test_add_reg
    word = RubyGBA::ASM.add_reg(4, 4, 2).unpack1("V")
    result = disasm(word)
    assert_includes result, "ADD"
    assert_includes result, "r4"
    assert_includes result, "r2"
  end

  def test_sub_reg
    word = RubyGBA::ASM.sub_reg(10, 10, 11).unpack1("V")
    result = disasm(word)
    assert_includes result, "SUB"
    assert_includes result, "r10"
    assert_includes result, "r11"
  end

  def test_cmp_reg
    word = RubyGBA::ASM.cmp_reg(10, 11).unpack1("V")
    result = disasm(word)
    assert_includes result, "CMP"
    assert_includes result, "r10"
    assert_includes result, "r11"
  end

  def test_and_reg
    word = RubyGBA::ASM.and_reg(11, 8, 11).unpack1("V")
    result = disasm(word)
    assert_includes result, "AND"
  end

  def test_eor_reg
    word = RubyGBA::ASM.eor_reg(8, 8, 9).unpack1("V")
    result = disasm(word)
    assert_includes result, "EOR"
  end

  def test_mov_reg
    word = RubyGBA::ASM.mov_reg(4, 3).unpack1("V")
    result = disasm(word)
    assert_includes result, "MOV"
    assert_includes result, "r4"
    assert_includes result, "r3"
  end

  def test_mvn_reg
    word = RubyGBA::ASM.mvn_reg(8, 8).unpack1("V")
    result = disasm(word)
    assert_includes result, "MVN"
    assert_includes result, "r8"
  end

  # ========================================================================
  # Shifts
  # ========================================================================

  def test_lsl_imm
    word = RubyGBA::ASM.lsl_imm(8, 8, 22).unpack1("V")
    result = disasm(word)
    assert_includes result, "LSL"
    assert_includes result, "r8"
    assert_includes result, "22"
  end

  def test_lsr_imm
    word = RubyGBA::ASM.lsr_imm(8, 8, 22).unpack1("V")
    result = disasm(word)
    assert_includes result, "LSR"
    assert_includes result, "r8"
    assert_includes result, "22"
  end

  def test_asr_imm
    word = RubyGBA::ASM.asr_imm(5, 5, 4).unpack1("V")
    result = disasm(word)
    assert_includes result, "ASR"
    assert_includes result, "r5"
    assert_includes result, "4"
  end

  # ========================================================================
  # Memory access
  # ========================================================================

  def test_ldr
    word = RubyGBA::ASM.ldr(10, 12).unpack1("V")
    result = disasm(word)
    assert_includes result, "LDR"
    assert_includes result, "r10"
    assert_includes result, "r12"
  end

  def test_str
    word = RubyGBA::ASM.str(10, 12).unpack1("V")
    result = disasm(word)
    assert_includes result, "STR"
    assert_includes result, "r10"
    assert_includes result, "r12"
  end

  def test_ldr_offset
    word = RubyGBA::ASM.ldr_offset(3, 1, 8).unpack1("V")
    result = disasm(word)
    assert_includes result, "LDR"
    assert_includes result, "r3"
    assert_includes result, "0x8"
  end

  def test_str_offset
    word = RubyGBA::ASM.str_offset(0, 1, 4).unpack1("V")
    result = disasm(word)
    assert_includes result, "STR"
    assert_includes result, "r0"
    assert_includes result, "r1"
  end

  def test_ldrh
    word = RubyGBA::ASM.load_halfword(1, 0).unpack1("V")
    result = disasm(word)
    assert_includes result, "LDRH"
    assert_includes result, "r1"
    assert_includes result, "r0"
  end

  def test_strh
    word = RubyGBA::ASM.store_halfword(0, 1).unpack1("V")
    result = disasm(word)
    assert_includes result, "STRH"
    assert_includes result, "r0"
    assert_includes result, "r1"
  end

  # ========================================================================
  # Multiply
  # ========================================================================

  def test_mul
    word = RubyGBA::ASM.mul(4, 5, 4).unpack1("V")
    result = disasm(word)
    assert_includes result, "MUL"
    assert_includes result, "r4"
    assert_includes result, "r5"
  end

  # ========================================================================
  # No ??? for anything we emit
  # ========================================================================

  def test_no_unknown_instructions_in_pong
    rom = RubyGBA.build("PONG", code: "BPNG", maker: "01", doctor: false) do
      display :bitmap
      set :state, 0
      scene :title do
        clear_screen :black
        draw_text "HI", 100, 76, :white
        if_pressed :start do
          set :state, 1
        end
      end
      scene :playing do
        clear_screen :blue
        if_held :up do
          sub :player_y, 2
        end
        add :player_y, 1
        clamp :player_y, 0, 136
        draw_rect_at 8, :player_y, 4, 24, :white
      end
      game_loop do
        wait_vblank
        case_var :state do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end

    inspector = RubyGBA::Inspector.from_rom(rom)
    code = rom.buffer.byteslice(0xC0, rom.code_offset - 0xC0)
    words = code.unpack("V*")

    unknowns = words.reject { |w| w == 0 }.select do |w|
      desc, = inspector.send(:disassemble, w, Array.new(16, 0))
      desc.start_with?("???")
    end

    assert_empty unknowns,
      "Inspector should decode all emitted instructions, but got ???: " \
      "#{unknowns.map { |w| '0x%08X' % w }}"
  end

  # ========================================================================
  # dump_func integration
  # ========================================================================

  def test_dump_func_prints_output
    output = capture_io do
      RubyGBA.build("TEST", code: "BTST", maker: "01", doctor: false) do
        func :my_func do
          set :x, 42
        end
        dump_func :my_func
        halt
      end
    end.first

    assert_includes output, "func :my_func"
    assert_includes output, "PUSH"
    assert_includes output, "POP"
  end

  def test_dump_func_works_with_scene_name
    output = capture_io do
      RubyGBA.build("TEST", code: "BTST", maker: "01", doctor: false) do
        scene :title do
          set :x, 1
        end
        dump_func :title
        halt
      end
    end.first

    assert_includes output, "_scene_title"
    assert_includes output, "PUSH"
  end

  def test_dump_func_warns_on_unknown
    output = capture_io do
      RubyGBA.build("TEST", code: "BTST", maker: "01", doctor: false) do
        dump_func :nonexistent
        halt
      end
    end.last  # stderr

    assert_includes output, "not found"
  end
end
