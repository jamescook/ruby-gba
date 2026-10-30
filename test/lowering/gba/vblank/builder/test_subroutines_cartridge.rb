# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_subroutines"

# `func` and `call` on the Advance's cartridge: the ARM they lower to, and a game of them run in
# the emulator. That they build, and the friendly errors for a misuse, are in
# test/all/vblank/builder/test_subroutines.rb.
class TestSubroutinesCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include SubroutinesGames

  private def instructions(rom)
    start = VBlank::Cartridge::ROM::ENTRY_OFFSET
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

  def test_func_emits_push_pop
    rom = build do
      func :noop do
        set! :x, 0
      end
      call :noop
      halt
    end

    insts = instructions(rom)
    # Should have PUSH {lr} = STMFD sp!, {r14}
    has_push_lr = insts.any? { |i| i == (0xE92D0000 | (1 << 14)) }
    assert has_push_lr, "func should emit PUSH {lr}"

    # Should have POP {pc} = LDMFD sp!, {r15}
    has_pop_pc = insts.any? { |i| i == (0xE8BD0000 | (1 << 15)) }
    assert has_pop_pc, "func should emit POP {pc}"
  end

  def test_call_emits_bl
    rom = build do
      func :my_func do
        set! :x, 42
      end
      call :my_func
      halt
    end

    insts = instructions(rom)
    # BL = 0xEB......
    has_bl = insts.any? { |i| (i >> 24) == 0xEB }
    assert has_bl, "call should emit BL instruction"
  end

  # ========================================================================
  # Integration: runs in mGBA
  # ========================================================================

  def test_subroutines_run_in_mgba
    rom = build do
      screen :bitmap

      func :clear do
        clear_screen :black
      end

      func :draw_pixel do
        # Draw a white pixel at (120, 80)
        pixel 120, 80, :white
      end

      game_loop do
        call :clear
        call :draw_pixel
      end
    end

    assert_emulator_loads_rom(rom, frames: 10)
  end
end
