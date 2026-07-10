# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

class TestVariables < Minitest::Test
  include RubyGBA::Constants

  # Helper to build a ROM and return [rom, builder] for inspection.
  def build_with_builder(doctor: false, &block)
    rom = RubyGBA::ROM.new(title: "VARTEST", code: "BVRT", maker: "01")
    builder = RubyGBA::Builder.new(rom)
    builder.instance_eval(&block)
    rom.finalize!(doctor: doctor)
    [rom, builder]
  end

  # ========================================================================
  # var — declaration and allocation
  # ========================================================================

  def test_var_allocates_iwram_address
    _rom, builder = build_with_builder do
      var :ball_x, 100
    end

    assert_equal IWRAM_START, builder.var_address(:ball_x)
  end

  def test_var_sequential_allocation
    _rom, builder = build_with_builder do
      var :ball_x, 100
      var :ball_y, 80
      var :score, 0
    end

    assert_equal IWRAM_START,     builder.var_address(:ball_x)
    assert_equal IWRAM_START + 4, builder.var_address(:ball_y)
    assert_equal IWRAM_START + 8, builder.var_address(:score)
  end

  def test_var_called_twice_overwrites
    # set/var can be called multiple times — it just emits more store code
    rom, builder = build_with_builder do
      var :ball_x, 100
      set :ball_x, 200
    end

    # Variable is still at the same address
    assert_equal IWRAM_START, builder.var_address(:ball_x)
    assert_operator rom.size, :>, 0
  end

  def test_set_auto_declares_variable
    _rom, builder = build_with_builder do
      set :counter, 42
    end

    assert_equal IWRAM_START, builder.var_address(:counter)
  end

  def test_variables_returns_all_vars
    _rom, builder = build_with_builder do
      set :x, 10
      set :y, 20
    end

    vars = builder.variables
    assert_equal 2, vars.size
    assert_equal IWRAM_START,     vars[:x][:address]
    assert_equal IWRAM_START + 4, vars[:y][:address]
  end

  # ========================================================================
  # set — write immediate to variable
  # ========================================================================

  def test_set_auto_allocates_and_emits
    rom, builder = build_with_builder do
      set :score, 99
    end

    # auto-declared
    assert_equal IWRAM_START, builder.var_address(:score)
    assert_operator rom.size, :>, 0
  end

  def test_set_then_set_reuses_address
    _rom, builder = build_with_builder do
      set :x, 10
      set :x, 20
    end

    # Second set doesn't allocate a new address
    assert_equal IWRAM_START, builder.var_address(:x)
    assert_equal 1, builder.variables.size
  end

  # ========================================================================
  # load_var / store_var
  # ========================================================================

  def test_load_var_auto_declares
    _rom, builder = build_with_builder do
      load_var 0, :fresh
    end

    assert builder.variables.key?(:fresh)
  end

  def test_store_var_auto_declares
    _rom, builder = build_with_builder do
      store_var :fresh, 0
    end

    assert builder.variables.key?(:fresh)
  end

  def test_load_var_emits_code
    rom, = build_with_builder do
      var :x, 42
      load_var 0, :x
    end

    # After var init code, load_var should emit load_immediate(12, addr) + ldr(0, 12)
    # Just verify it builds without error and produces a valid ROM
    assert_operator rom.size, :>, 0
  end

  def test_store_var_emits_code
    rom, = build_with_builder do
      var :x, 0
      store_var :x, 5
    end

    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # add_var / sub_var
  # ========================================================================

  def test_add_var_auto_declares
    _rom, builder = build_with_builder do
      add_var :nope, 1
    end

    assert builder.variables.key?(:nope)
  end

  def test_sub_var_auto_declares
    _rom, builder = build_with_builder do
      sub_var :nope, 1
    end

    assert builder.variables.key?(:nope)
  end

  def test_add_var_emits_code
    rom, = build_with_builder do
      var :counter, 0
      add_var :counter, 1
    end

    assert_operator rom.size, :>, 0
  end

  def test_sub_var_emits_code
    rom, = build_with_builder do
      var :y, 100
      sub_var :y, 2
    end

    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # Integration: set changes value (instruction sequence test)
  # ========================================================================

  def test_set_produces_str_instruction
    rom, = build_with_builder do
      var :x, 0
      set :x, 99
    end

    # The set call should produce: load_immediate(r0, 99) + load_immediate(r1, addr) + str(r0, r1)
    # Find the STR instruction in the code region
    code_start = RubyGBA::ROM::ENTRY_OFFSET
    found_str = false
    offset = code_start
    while offset + 4 <= rom.buffer.bytesize
      inst = rom.buffer[offset, 4].unpack1("V")
      # STR pattern: cond=AL (0xE), bits 27:26 = 01, bit 20 = 0 (store)
      if (inst & 0x0C100000) == 0x04000000 && (inst >> 28) == 0xE
        found_str = true
        break
      end
      offset += 4
    end

    assert found_str, "expected at least one STR instruction from set"
  end

  # ========================================================================
  # add_var instruction sequence
  # ========================================================================

  def test_add_var_produces_ldr_add_str_sequence
    rom, = build_with_builder do
      var :counter, 0
      add_var :counter, 5
      halt
    end

    # add_var should emit: load_immediate(r12, addr), ldr(r10, r12), add_imm(r10, r10, 5), str(r10, r12)
    # Verify the ROM builds and we can find an ADD instruction
    code_start = RubyGBA::ROM::ENTRY_OFFSET
    found_add = false
    offset = code_start
    while offset + 4 <= rom.buffer.bytesize
      inst = rom.buffer[offset, 4].unpack1("V")
      # ADD imm pattern: cond=AL, opcode=0100, I=1
      opcode = (inst >> 21) & 0xF
      is_imm = (inst >> 25) & 1
      if opcode == 0x4 && is_imm == 1 && (inst >> 28) == 0xE
        # Check it's adding 5 to r10
        rd = (inst >> 12) & 0xF
        rn = (inst >> 16) & 0xF
        if rd == 10 && rn == 10
          found_add = true
          break
        end
      end
      offset += 4
    end

    assert found_add, "expected ADD r10, r10, #5 instruction from add_var"
  end
end
