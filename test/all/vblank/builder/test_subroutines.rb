# frozen_string_literal: true

require "test_helper"

# `func` and `call`: that a game of them builds, and the friendly errors for a misuse. The ARM
# they lower to, and a game of them run in the emulator, are in
# test/lowering/gba/vblank/builder/test_subroutines_cartridge.rb.

# How both files build a game.
module SubroutinesGames
  private def build(validate: false, &block)
    VBlank.build("SUBTEST", console: :gba, code: "BSUB", maker: "01", validate: validate, out: nil, err: nil, &block)
  end
end

class TestSubroutines < Minitest::Test
  include VBlank::Console::Hardware
  include SubroutinesGames

  # ========================================================================
  # Basic func/call
  # ========================================================================

  def test_func_and_call_builds
    rom = build do
      func :reset_ball do
        set! :ball_x, 120
        set! :ball_y, 80
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
        set! :ball_x, 120
      end
    end

    assert_operator rom.size, :>, 0
  end

  def test_multiple_calls_to_same_func
    rom = build do
      func :inc_score do
        add_var! :score, 1
      end

      call :inc_score
      call :inc_score
      call :inc_score
      halt
    end

    assert_operator rom.size, :>, 0
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
        add_var! :ball_x, 2
        if_ge :ball_x, 240 do
          set! :ball_x, 0
        end
      end

      set! :ball_x, 120
      game_loop do
        call :update_ball
      end
    end

    assert_operator rom.size, :>, 0
  end

  def test_func_calling_another_func
    rom = build do
      func :inner do
        set! :x, 1
      end

      func :outer do
        call :inner
        set! :y, 2
      end

      call :outer
      halt
    end

    assert_operator rom.size, :>, 0
  end
end
