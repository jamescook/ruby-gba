# frozen_string_literal: true

require "test_helper"

# Per-scene screen mode: a game can run different scenes in different screen
# modes, switching the hardware as each scene takes over. The common shape is a
# colorful direct-color title (Mode 3, no tear risk because it's static) and a
# heavy-redraw gameplay scene in tear-proof double buffering (Mode 4). A scene
# declares its mode with a `screen` at its top; the framework handles the switch.
#
# Both scenes must render correctly on the console, which means the mode transition
# (Mode 3 -> Mode 4) has to actually happen: the palette is uploaded, the pages are
# set up, and the flip only runs while the buffered scene is live. That is read off the
# Advance's cartridge in the emulator, with what its lowering makes of a palette and a routine
# shared by scenes of two modes, in test/lowering/gba/vblank/ir/test_per_scene_mode_cartridge.rb.

# The game both files play.
module PerSceneModeGames
  # A direct-color (Mode 3) title in red; START switches to a double-buffered
  # (Mode 4) play scene showing a blue field with a green cell.
  private def mixed_program
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap # default: direct-color Mode 3
      var :state, 0
      scene :title do
        clear_screen :red
        pressed(:start).then { set! :state, 1 }
      end
      scene :play do
        screen :bitmap, tear_free: true # this scene is double-buffered
        clear_screen :blue
        dma_fill_rect 100, 76, 8, 8, :green
      end
      game_loop do
        wait_vblank
        case_var :state do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    b.finalize_program
    b.program
  end
end

class TestPerSceneMode < Minitest::Test
  include PerSceneModeGames

  # Oracle: the interpreter draws the same pixels regardless of mode, so it pins
  # what each scene should show — red on the title, blue + green once playing.
  def test_the_interpreter_renders_each_scene
    red = game_player.run(mixed_program) # no input: stays on the title
    assert_equal Color.resolve(:red), red.screen.pixel(0, 0)

    playing = game_player.input_each_frame { |_f| [:start] }.run(mixed_program)
    assert_equal Color.resolve(:blue), playing.screen.pixel(0, 0)
    assert_equal Color.resolve(:green), playing.screen.pixel(103, 79)
  end

  # --- a per-frame routine (once_a_frame) is not a scene ---
  #
  # `once_a_frame` (the machinery behind `flash_screen`/`pulse`/`shake_screen`/
  # `camera_follows`/`fade_out`/`fade_in`) compiles to a plain func called directly
  # from the main loop body, every real frame, regardless of which scene (if any)
  # is active. It must never be treated as an entry point that "owns" a display
  # mode the way a case_var scene does — if it were, its own mode-switch preamble
  # would fight whatever scene is actually live, forcing the hardware back to its
  # mode every frame. Concretely: in a program that also switches screen modes per
  # scene, that fight makes the active scene re-run ITS OWN mode-entry preamble
  # every frame too — which, for a tiled/affine scene, means the OAM sprite table
  # gets cleared again right after this frame's sprites were written, so nothing
  # composited ever reaches the screen. See IR::Modes#scene_targets /
  # #main_body_call_targets, and examples/pong.rb's title screen for the real case
  # this was found in (a `flash_screen` inside an unrelated, unreached func was
  # enough to trigger it).
  def test_a_per_frame_routine_is_not_a_scene
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      var :state, 0
      once_a_frame(:tick) { }
      scene(:a) { }
      game_loop { wait_vblank; case_var(:state) { when_val 0, :a } }
    end
    b.finalize_program
    modes = VBlank::IR::Modes.resolve(b.program)

    refute_includes modes.scene_funcs, :tick,
                     "a per-frame routine must not be treated as a mode-owning scene"
    assert_includes modes.scene_funcs.map { |n| VBlank::IR::Modes.strip_scene_prefix(n) }, "a",
                     "a real case_var scene must still be tracked"
  end
end
