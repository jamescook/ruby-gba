# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

class TestInput < Minitest::Test
  include RubyGBA::Constants

  def build(doctor: false, &block)
    RubyGBA.build("INPTEST", code: "BINP", maker: "01", doctor: doctor, &block)
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
  # if_held
  # ========================================================================

  def test_if_held_builds_without_error
    rom = build do
      display :bitmap
      set :player_y, 80
      game_loop do
        wait_vblank
        if_held :up do
          sub_var :player_y, 2
        end
      end
    end

    assert_operator rom.size, :>, 0
  end

  def test_if_held_unknown_button_raises
    assert_raises(ArgumentError) do
      build do
        if_held :turbo do
          halt
        end
      end
    end
  end

  def test_if_held_all_buttons
    # Every button should be accepted without error
    %i[a b select start right left up down r l].each do |btn|
      rom = build do
        if_held btn do
          set :x, 1
        end
        halt
      end
      assert_operator rom.size, :>, 0, "button #{btn} should work"
    end
  end

  def test_if_held_emits_conditional_branch
    rom = build do
      if_held :up do
        set :y, 1
      end
      halt
    end

    insts = instructions(rom)
    # Should contain a BNE (cond=0x1) that skips over the block
    has_bne = insts.any? { |i| branch?(i) && cond(i) == 0x1 }
    assert has_bne, "expected BNE (skip block if button not pressed)"
  end

  def test_if_held_branch_skips_correct_distance
    rom = build do
      if_held :a do
        set :x, 42
      end
      halt
    end

    insts = instructions(rom)
    # Find the BNE instruction
    bne_idx = insts.index { |i| branch?(i) && cond(i) == 0x1 }
    refute_nil bne_idx, "should have a BNE"

    # Decode the branch target
    offset = signed_branch_offset(insts[bne_idx])
    target_idx = bne_idx + 2 + offset  # PC is 2 ahead

    # The halt (loop_forever) should be at or after target_idx
    halt_idx = insts.index(0xEAFFFFFE)
    assert_operator target_idx, :<=, halt_idx + 1,
      "BNE should skip to the instruction after the set block"
  end

  # ========================================================================
  # if_pressed (edge detection)
  # ========================================================================

  def test_if_pressed_builds_without_error
    rom = build do
      display :bitmap
      game_loop do
        wait_vblank
        if_pressed :start do
          set :state, 1
        end
      end
    end

    assert_operator rom.size, :>, 0
  end

  def test_if_pressed_uses_prev_keys_variable
    _rom, builder = build_with_builder do
      if_pressed :start do
        set :state, 1
      end
      halt
    end

    assert builder.variables.key?(:_prev_keys),
      "if_pressed should auto-allocate :_prev_keys variable"
  end

  def test_if_pressed_emits_beq
    rom = build do
      if_pressed :start do
        set :state, 1
      end
      halt
    end

    insts = instructions(rom)
    # if_pressed uses BEQ to skip (Z=1 means not newly pressed)
    has_beq = insts.any? { |i| branch?(i) && cond(i) == 0x0 }
    assert has_beq, "expected BEQ (skip block if button not newly pressed)"
  end

  # ========================================================================
  # Integration: runs in mGBA
  # ========================================================================

  def test_input_rom_runs_in_mgba
    mgba_bin = MGBA_BIN
    skip "teek-mgba not found" unless mgba_bin

    rom = build do
      display :bitmap
      set :player_y, 80
      game_loop do
        wait_vblank
        if_held :up do
          sub_var :player_y, 2
        end
        if_held :down do
          add_var :player_y, 2
        end
        if_pressed :start do
          set :player_y, 80
        end
      end
    end

    Tempfile.create(["inputtest", ".gba"]) do |f|
      rom.write(f.path)
      output = `"#{mgba_bin}" --frames 10 --headless "#{f.path}" 2>&1`
      assert_equal 0, $?.exitstatus, "ROM should run without crashing: #{output}"
    end
  end

  private

  def build_with_builder(doctor: false, &block)
    rom = RubyGBA::ROM.new(title: "INPTEST", code: "BINP", maker: "01")
    builder = RubyGBA::Builder.new(rom)
    builder.instance_eval(&block)
    rom.finalize!(doctor: doctor)
    [rom, builder]
  end

  def branch?(inst)
    (inst & 0x0E000000) == 0x0A000000
  end

  def cond(inst)
    (inst >> 28) & 0xF
  end

  def signed_branch_offset(inst)
    offset = inst & 0x00FFFFFF
    (offset & 0x800000) != 0 ? offset - 0x1000000 : offset
  end
end
