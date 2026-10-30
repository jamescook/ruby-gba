# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_scenes"

# Scenes and `case_var` on the Advance's own cartridge: that each shape builds into one, and what
# its console runs, read in the emulator. What every run plays is in
# test/all/vblank/builder/test_scenes.rb, which keeps the games both files play in ScenesGames.
class TestScenesCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include ScenesGames

  private def build(validate: false, &block)
    VBlank.build("SCNTEST", console: :gba, code: "BSCN", maker: "01", validate: validate, out: nil, err: nil, &block)
  end

  # ========================================================================
  # scene
  # ========================================================================

  def test_scene_builds
    rom = build do
      screen :bitmap
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
        set! :x, 1
      end
      scene :title do
        set! :x, 2
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
      screen :bitmap
      scene :title do
        clear_screen :black
      end
      scene :playing do
        clear_screen :blue
      end

      set! :state, 0
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
      screen :bitmap

      scene :title do
        clear_screen :black
        draw_text "PONG", 96, 40, :white
      end

      scene :playing do
        clear_screen :black
      end

      set! :state, 0
      game_loop do
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
      screen :bitmap

      scene :title do
        clear_screen :black
        draw_text "PRESS START", 64, 100, :white
        if_pressed :start do
          set! :state, 1
        end
      end

      scene :playing do
        clear_screen :blue
      end

      set! :state, 0
      game_loop do
        case_var :state do
          when_val 0, :title
          when_val 1, :playing
        end
      end
    end
    assert_operator rom.size, :>, 0
  end

  # Regression: case_var must reload the variable before each comparison, since a
  # called scene clobbers scratch registers. The observable guarantee is that
  # exactly one scene runs — the matching one — even with a scene between two
  # other comparisons. Each scene clears the whole screen, so a stale compare
  # that ran a second scene would leave the wrong color on screen.
  def test_case_var_dispatches_to_only_the_matching_scene
    rom = build do
      screen :bitmap

      scene :red_scene   do clear_screen :red end
      scene :blue_scene  do clear_screen :blue end
      scene :green_scene do clear_screen :green end

      set! :state, 1
      case_var :state do
        when_val 0, :red_scene
        when_val 1, :blue_scene   # the match — runs, then clobbers scratch
        when_val 2, :green_scene  # must NOT run: state is reloaded, still 1
      end
      halt
    end

    v = assert_emulator_loads_rom(rom, frames: 5)
    assert v.blue?(120, 80), "state == 1 should run the blue scene"
    refute v.green?(120, 80), "a stale comparison must not also run the green scene"
  end

  def test_a_scene_that_hands_on_does_not_run_the_scene_it_hands_to_on_hardware
    rom = build { HANDING_ON.call(self) }
    v = assert_emulator_loads_rom(rom, frames: 5, vars: rom.var_addresses)

    assert_equal [1, 0, 0], [v.var(:ran_first), v.var(:ran_second), v.var(:ran_third)],
                 "the console ran more than one scene in a pass — a transition fell through the table"
    assert_equal 1, v.var(:state)
  end

  # ========================================================================
  # scene loads_first: its pictures go up on a pass of their own
  # ========================================================================

  # The console counts the same passes, however many frames it took to start the game.
  def test_the_console_starts_a_scene_that_loads_first_on_the_pass_after
    rom = assemble_rom(handing_over(loads_first: true), name: "SCNPASS")
    v = assert_emulator_loads_rom(rom, frames: 12, vars: rom.var_addresses)

    assert_equal 4, v.var(:began)
  end

  def test_the_console_starts_a_scene_that_loads_first_and_is_up_at_power_on_on_the_first_pass
    rom = assemble_rom(handing_over(loads_first: true, first: 1), name: "SCNPOWER")
    v = assert_emulator_loads_rom(rom, frames: 8, vars: rom.var_addresses)

    assert_equal 0, v.var(:began)
  end

  # ========================================================================
  # func declared from inside another func's body
  # ========================================================================

  def test_a_func_declared_inside_another_func_body_is_built_on_hardware
    rom = build { DECLARED_INSIDE.call(self) }
    v = assert_emulator_loads_rom(rom, frames: 5, vars: rom.var_addresses)

    assert_equal [1, 1, 1], [v.var(:ran_outer), v.var(:ran_middle), v.var(:ran_inner)]
  end

  # ========================================================================
  # Integration: runs in mGBA
  # ========================================================================

  def test_scenes_run_in_mgba
    rom = build do
      screen :bitmap

      scene :title do
        clear_screen :black
        draw_text "HELLO", 100, 76, :white
      end

      scene :other do
        clear_screen :red
      end

      set! :state, 0
      game_loop do
        case_var :state do
          when_val 0, :title
          when_val 1, :other
        end
      end
    end

    assert_emulator_loads_rom(rom, frames: 30)
  end
end
