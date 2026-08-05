# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

class TestSubroutines < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  def build(validate: false, &block)
    RubyGBA.build("SUBTEST", code: "BSUB", maker: "01", validate: validate, &block)
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
  # Basic func/call
  # ========================================================================

  def test_func_and_call_builds
    rom = build do
      func :reset_ball do
        set :ball_x, 120
        set :ball_y, 80
      end

      call :reset_ball
      halt
    end

    assert_operator rom.size, :>, 0
  end

  def test_call_before_func_definition
    # Order shouldn't matter — call before func should work
    rom = build do
      call :reset_ball
      halt

      func :reset_ball do
        set :ball_x, 120
      end
    end

    assert_operator rom.size, :>, 0
  end

  def test_multiple_calls_to_same_func
    rom = build do
      func :inc_score do
        add_var :score, 1
      end

      call :inc_score
      call :inc_score
      call :inc_score
      halt
    end

    assert_operator rom.size, :>, 0
  end

  def test_func_emits_push_pop
    rom = build do
      func :noop do
        set :x, 0
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
        set :x, 42
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
  # Error cases
  # ========================================================================

  def test_duplicate_func_raises
    assert_raises(ArgumentError) do
      build do
        func :foo do; end
        func :foo do; end
      end
    end
  end

  def test_call_undefined_func_raises
    assert_raises(ArgumentError) do
      build do
        call :nonexistent
        halt
      end
    end
  end

  # ========================================================================
  # Func with game loop
  # ========================================================================

  def test_func_called_from_game_loop
    rom = build do
      screen :bitmap

      func :update_ball do
        add_var :ball_x, 2
        if_ge :ball_x, 240 do
          set :ball_x, 0
        end
      end

      set :ball_x, 120
      game_loop do
        call :update_ball
      end
    end

    assert_operator rom.size, :>, 0
  end

  def test_func_calling_another_func
    rom = build do
      func :inner do
        set :x, 1
      end

      func :outer do
        call :inner
        set :y, 2
      end

      call :outer
      halt
    end

    assert_operator rom.size, :>, 0
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

    assert_gemba_loads_rom(rom, frames: 10)
  end
end
