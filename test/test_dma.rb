# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

class TestDMA < Minitest::Test
  include RubyGBA::Constants

  def build(doctor: false, &block)
    RubyGBA.build("DMATEST", code: "BDMA", maker: "01", doctor: doctor, &block)
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
  # clear_screen
  # ========================================================================

  def test_clear_screen_builds
    rom = build do
      display :bitmap
      clear_screen :black
      halt
    end

    assert_operator rom.size, :>, 0
  end

  def test_clear_screen_emits_dma_registers
    rom = build do
      display :bitmap
      clear_screen :red
      halt
    end

    # Should write to DMA3SAD, DMA3DAD, DMA3CNT
    # Look for stores to these I/O addresses in the instruction stream
    insts = instructions(rom)
    addresses_stored = find_store_targets(rom)

    assert_includes addresses_stored, REG_DMA3SAD, "should write DMA3 source address"
    assert_includes addresses_stored, REG_DMA3DAD, "should write DMA3 destination address"
    assert_includes addresses_stored, REG_DMA3CNT, "should write DMA3 control"
  end

  def test_clear_screen_much_smaller_than_fill_rect
    rom_dma = build do
      display :bitmap
      clear_screen :red
      halt
    end

    rom_pixel = build do
      display :bitmap
      fill_rect 0, 0, 240, 160, :red
      halt
    end

    # DMA clear should be way smaller than pixel-by-pixel fill
    assert_operator rom_dma.size, :<, rom_pixel.size / 10,
      "DMA clear should be dramatically smaller than pixel fill"
  end

  # ========================================================================
  # dma_fill_rect
  # ========================================================================

  def test_dma_fill_rect_builds
    rom = build do
      display :bitmap
      dma_fill_rect 10, 10, 40, 30, :blue
      halt
    end

    assert_operator rom.size, :>, 0
  end

  def test_dma_fill_rect_emits_multiple_transfers
    rom = build do
      display :bitmap
      dma_fill_rect 10, 10, 40, 3, :green
      halt
    end

    # 3 rows = 3 DMA transfers, each writing to DMA3CNT
    addresses = find_store_targets(rom)
    cnt_count = addresses.count(REG_DMA3CNT)
    assert_equal 3, cnt_count, "3-row fill should emit 3 DMA3CNT writes"
  end

  # ========================================================================
  # Integration: DMA clear looks correct in mGBA
  # ========================================================================

  def test_clear_screen_renders_in_mgba
    begin
      require "teek/mgba/core"
      require "teek_mgba"
    rescue LoadError
      skip "teek-mgba not compiled"
    end

    rom = build do
      display :bitmap
      clear_screen :red
      halt
    end

    verifier = RubyGBA::Verifier.new(rom, frames: 5)
    # Center pixel should be red
    assert verifier.red?(120, 80), "center should be red after clear_screen :red"
    # Corners too
    assert verifier.red?(0, 0), "top-left should be red"
    assert verifier.red?(239, 159), "bottom-right should be red"
  end

  def test_dma_fill_rect_renders_in_mgba
    begin
      require "teek/mgba/core"
      require "teek_mgba"
    rescue LoadError
      skip "teek-mgba not compiled"
    end

    rom = build do
      display :bitmap
      clear_screen :black
      dma_fill_rect 100, 60, 40, 40, :green
      halt
    end

    verifier = RubyGBA::Verifier.new(rom, frames: 5)
    # Inside the rect should be green
    assert verifier.green?(120, 80), "center of rect should be green"
    # Outside should be black
    assert verifier.black?(10, 10), "outside rect should be black"
  end

  def test_game_loop_with_clear_screen_runs
    mgba_bin = MGBA_BIN
    skip "teek-mgba not found" unless mgba_bin

    rom = build do
      display :bitmap
      game_loop do
        wait_vblank
        clear_screen :black
        dma_fill_rect 100, 60, 40, 40, :white
      end
    end

    Tempfile.create(["dmaloop", ".gba"]) do |f|
      rom.write(f.path)
      output = `"#{mgba_bin}" --frames 10 --headless "#{f.path}" 2>&1`
      assert_equal 0, $?.exitstatus, "ROM should run: #{output}"
    end
  end

  private

  # Scan the instruction stream for load_immediate sequences that load
  # known DMA register addresses, then look for subsequent STR instructions.
  # Returns an array of target addresses that were stored to.
  def find_store_targets(rom)
    targets = []
    start = RubyGBA::ROM::ENTRY_OFFSET
    offset = start

    while offset + 4 <= rom.buffer.bytesize
      word = rom.buffer[offset, 4].unpack1("V")
      break if word == 0

      # Look for load_immediate sequences targeting r1 (address register)
      # followed by STR r0, [r1]
      # Simplified: just decode load_immediate values going into r1
      opcode = (word >> 21) & 0xF
      rd = (word >> 12) & 0xF
      i_bit = (word >> 25) & 1

      if rd == 1 && i_bit == 1 && (opcode == 0xD || opcode == 0xC)
        # This is loading a value into r1 — track the accumulated value
        imm8 = word & 0xFF
        rot = ((word >> 8) & 0xF) * 2
        rotated = rot == 0 ? imm8 : (((imm8 >> rot) | (imm8 << (32 - rot))) & 0xFFFFFFFF)

        if opcode == 0xD  # MOV
          @_tracking_r1 = rotated
        elsif opcode == 0xC  # ORR
          @_tracking_r1 = (@_tracking_r1 || 0) | rotated
        end
      elsif (word & 0x0FF00000) == 0x05800000  # STR rd, [r1] pattern
        targets << @_tracking_r1 if @_tracking_r1
      end

      offset += 4
    end

    targets
  end
end
