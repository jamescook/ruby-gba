# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

class TestConditionals < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  def build(validate: false, &block)
    RubyGBA.build("CONDTEST", code: "BCND", maker: "01", validate: validate, &block)
  end

  def instructions(rom)
    start = RubyGBA::ROM::ENTRY_OFFSET
    result = []
    offset = start
    while offset + 4 <= rom.buffer.bytesize
      word = rom.buffer[offset, 4].unpack1("V")
      break if word == 0
      result << word
      offset += 4
    end
    result
  end

  # ========================================================================
  # if_eq / if_ne — variable vs immediate
  # ========================================================================

  def test_if_eq_builds
    rom = build do
      set :state, 0
      if_eq :state, 0 do
        set :x, 1
      end
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_if_ne_builds
    rom = build do
      set :state, 1
      if_ne :state, 0 do
        set :x, 1
      end
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # if_gt / if_lt / if_ge / if_le — variable vs immediate
  # ========================================================================

  def test_if_gt_builds
    rom = build do
      set :score, 5
      if_gt :score, 3 do
        set :winner, 1
      end
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_if_lt_builds
    rom = build do
      set :y, 0
      if_lt :y, 10 do
        set :y, 10
      end
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_if_ge_builds
    rom = build do
      set :score, 5
      if_ge :score, 5 do
        set :state, 2
      end
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_if_le_builds
    rom = build do
      set :y, 0
      if_le :y, 0 do
        set :dy, 1
      end
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # Aliases: if_gte, if_lte
  # ========================================================================

  def test_if_gte_is_alias_for_if_ge
    rom = build do
      set :score, 5
      if_gte :score, 5 do
        set :state, 2
      end
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_if_lte_is_alias_for_if_le
    rom = build do
      set :y, 0
      if_lte :y, 0 do
        set :dy, 1
      end
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # Variable vs variable comparisons
  # ========================================================================

  def test_if_gt_variable_vs_variable
    rom = build do
      set :ball_y, 100
      set :cpu_center, 80
      if_gt :ball_y, :cpu_center do
        add_var :cpu_y, 1
      end
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_if_lt_variable_vs_variable
    rom = build do
      set :ball_y, 50
      set :cpu_center, 80
      if_lt :ball_y, :cpu_center do
        sub_var :cpu_y, 1
      end
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # Conditional emits correct branch type
  # ========================================================================

  def test_if_eq_emits_bne_to_skip
    rom = build do
      set :state, 0
      if_eq :state, 0 do
        set :x, 1
      end
      halt
    end

    insts = instructions(rom)
    # if_eq skips with BNE (inverse of EQ)
    has_bne = insts.any? { |i| branch?(i) && cond(i) == 0x1 }
    assert has_bne, "if_eq should emit BNE to skip block"
  end

  def test_if_gt_emits_ble_to_skip
    rom = build do
      set :score, 5
      if_gt :score, 3 do
        set :winner, 1
      end
      halt
    end

    insts = instructions(rom)
    # if_gt skips with BLE (inverse of GT)
    has_ble = insts.any? { |i| branch?(i) && cond(i) == 0xD }
    assert has_ble, "if_gt should emit BLE to skip block"
  end

  def test_if_lt_emits_bge_to_skip
    rom = build do
      set :y, 0
      if_lt :y, 10 do
        set :y, 10
      end
      halt
    end

    insts = instructions(rom)
    # if_lt skips with BGE (inverse of LT)
    has_bge = insts.any? { |i| branch?(i) && cond(i) == 0xA }
    assert has_bge, "if_lt should emit BGE to skip block"
  end

  # ========================================================================
  # Large immediate (can't encode as rotated 8-bit)
  # ========================================================================

  def test_if_ge_large_immediate
    rom = build do
      set :ball_y, 156
      if_ge :ball_y, 156 do
        set :ball_dy, 0
      end
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # Nested conditionals
  # ========================================================================

  def test_nested_conditionals
    rom = build do
      set :score, 5
      set :state, 1
      if_ge :score, 5 do
        if_eq :state, 1 do
          set :state, 2
        end
      end
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # Integration: runs in mGBA
  # ========================================================================

  def test_conditionals_run_in_mgba
    rom = build do
      display :bitmap
      set :state, 0
      set :ball_x, 120
      set :ball_y, 80
      game_loop do
        wait_vblank
        clear_screen :black
        add_var :ball_x, 1
        if_ge :ball_x, 240 do
          set :ball_x, 0
        end
        if_le :ball_y, 0 do
          set :ball_y, 0
        end
      end
    end

    assert_gemba_loads_rom(rom, frames: 60)
  end

  private

  def branch?(inst)
    (inst & 0x0E000000) == 0x0A000000
  end

  def cond(inst)
    (inst >> 28) & 0xF
  end
end
