# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

class TestScenes < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  def build(doctor: false, &block)
    RubyGBA.build("SCNTEST", code: "BSCN", maker: "01", doctor: doctor, &block)
  end

  # ========================================================================
  # scene
  # ========================================================================

  def test_scene_builds
    rom = build do
      scene :title do
        clear_screen :black
      end
      call :_scene_title
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_scene_does_not_clash_with_func
    rom = build do
      func :title do
        set :x, 1
      end
      scene :title do
        set :x, 2
      end
      call :title
      call :_scene_title
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # case_var
  # ========================================================================

  def test_case_var_builds
    rom = build do
      scene :title do
        clear_screen :black
      end
      scene :playing do
        clear_screen :blue
      end

      set :state, 0
      case_var :state do
        when_val 0, :title
        when_val 1, :playing
      end
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_case_var_with_game_loop
    rom = build do
      display :bitmap

      scene :title do
        clear_screen :black
        draw_text "PONG", 96, 40, :white
      end

      scene :playing do
        clear_screen :black
      end

      set :state, 0
      game_loop do
        wait_vblank
        case_var :state do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end
    assert_operator rom.size, :>, 0
  end

  def test_case_var_with_input_transition
    rom = build do
      display :bitmap

      scene :title do
        clear_screen :black
        draw_text "PRESS START", 64, 100, :white
        if_pressed :start do
          set :state, 1
        end
      end

      scene :playing do
        clear_screen :blue
      end

      set :state, 0
      game_loop do
        wait_vblank
        case_var :state do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end
    assert_operator rom.size, :>, 0
  end

  # Regression: case_var must reload the variable before each comparison.
  # Scene calls clobber r10 (used by add/sub/conditionals), so if case_var
  # loaded once at the top, later comparisons would use stale r10 values.
  def test_case_var_reloads_variable_after_scene_call
    rom = build do
      display :bitmap

      scene :title do
        # This clobbers r10 — add loads var into r10 internally
        add :frame_count, 1
      end

      scene :playing do
        clear_screen :blue
      end

      set :state, 0
      case_var :state do
        when_val 0, :title
        when_val 1, :playing
      end
      halt
    end

    # Extract the code after emit_pending_functions.
    # Each case branch should have a load_var_into(10, :state) before CMP.
    # Count how many LDR r10, [r12] instructions appear in the case_var region.
    code = rom.buffer.byteslice(RubyGBA::ROM::ENTRY_OFFSET, rom.code_offset - RubyGBA::ROM::ENTRY_OFFSET)
    words = code.unpack("V*")

    # LDR r10, [r12] = 0xE59CA000
    ldr_r10_r12 = 0xE59CA000
    load_count = words.count { |w| w == ldr_r10_r12 }

    # Should have at least 2 loads of r10 from r12 (one per when_val case)
    assert_operator load_count, :>=, 2,
      "case_var should reload the state variable before each comparison (found #{load_count} loads)"
  end

  # ========================================================================
  # Integration: runs in mGBA
  # ========================================================================

  def test_scenes_run_in_mgba
    rom = build do
      display :bitmap

      scene :title do
        clear_screen :black
        draw_text "HELLO", 100, 76, :white
      end

      scene :other do
        clear_screen :red
      end

      set :state, 0
      game_loop do
        wait_vblank
        case_var :state do
          when_val 0, :title
          when_val 1, :other
        end
      end
    end

    assert_gemba_loads_rom(rom, frames: 30)
  end
end
