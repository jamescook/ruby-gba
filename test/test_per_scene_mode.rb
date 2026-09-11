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
# set up, and the flip only runs while the buffered scene is live.
class TestPerSceneMode < Minitest::Test
  include RubyGBA::Constants

  Build = RubyGBA::IR::Build

  # A direct-color (Mode 3) title in red; START switches to a double-buffered
  # (Mode 4) play scene showing a blue field with a green cell.
  def mixed_program
    b = Builder.new
    b.instance_eval do
      screen :bitmap # default: direct-color Mode 3
      var :state, 0
      scene :title do
        clear_screen :red
        pressed(:start).then { set :state, 1 }
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
    b.emit_pending_functions
    b.program
  end

  # Oracle: the interpreter draws the same pixels regardless of mode, so it pins
  # what each scene should show — red on the title, blue + green once playing.
  def test_the_interpreter_renders_each_scene
    red = Reference.new.run(mixed_program) # no input: stays on the title
    assert_equal Color.resolve(:red), red.screen.pixel(0, 0)

    playing = Reference.new.input_each_frame { |_f| [:start] }.run(mixed_program)
    assert_equal Color.resolve(:blue), playing.screen.pixel(0, 0)
    assert_equal Color.resolve(:green), playing.screen.pixel(103, 79)
  end

  # The direct-color title renders on the console (Mode 3, 15-bit color).
  def test_the_direct_color_title_renders_on_the_console
    rom = assemble_rom(mixed_program, name: "MIX")
    v = assert_emulator_loads_rom(rom, frames: 4) # no input: the Mode 3 title
    assert v.red?(0, 0), "the direct-color title should be red, got 0x#{format('%04X', v.pixel_gba(0, 0))}"
  end

  # After START, the game switches into the buffered scene, which must render
  # through the auto palette — proof the Mode 3 -> Mode 4 transition works.
  def test_the_buffered_scene_renders_after_the_switch
    rom = assemble_rom(mixed_program, name: "MIX")
    v = assert_emulator_loads_rom(rom, frames: 8, keys: KEY_START)
    assert v.blue?(0, 0), "the buffered play field should be blue, got 0x#{format('%04X', v.pixel_gba(0, 0))}"
    assert v.green?(103, 79), "the buffered green cell should render, got 0x#{format('%04X', v.pixel_gba(103, 79))}"
  end

  # The buffered palette is built from the buffered scenes only. A colorful
  # direct-color scene stores full colors per pixel and needs no palette slots, so
  # its colors can't crowd the 256-entry table — the program lowers cleanly where
  # the old whole-program collection would have tripped a false overflow.
  def test_a_colorful_direct_scene_does_not_overflow_the_buffered_palette
    prog = Build.program(
      Build.screen(:bitmap),        # boot: direct color
      Build.set(:state, Build.int(0)),
      # A direct scene painting 250 distinct raw colors — far past the 256-slot
      # table, but direct color needs no palette, so none of these count toward it.
      Build.func(:_scene_gallery, *(1..250).map { |c| Build.pixel(0, 0, c) }),
      # The buffered scene uses just a few colors.
      Build.func(:_scene_play, Build.screen(:bitmap, buffered: true),
                 Build.clear_screen(:blue), Build.dma_fill_rect(0, 0, 8, 8, :green)),
      Build.loop_(Build.wait_vblank,
                  Build.case_(:state, [[0, :_scene_gallery], [1, :_scene_play]])),
    )

    # Would raise Palette::Overflow if the direct scene's 250 colors were counted.
    code = GBA.new.lower(prog)
    assert_operator code.bytesize, :>, 0
  end

  # A drawing routine reached from scenes of different modes can't be lowered both
  # ways — that's a friendly build error, not a silently-wrong screen.
  def test_a_draw_helper_shared_across_modes_is_a_friendly_error
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      var :state, 0
      func :paint do
        clear_screen :white
      end
      scene :a do
        call :paint # direct
      end
      scene :b do
        screen :bitmap, tear_free: true
        call :paint # buffered — the same routine, now a different mode
      end
      game_loop do
        wait_vblank
        case_var :state do
          when_val 0, :a
          when_val 1, :b
        end
      end
    end
    b.emit_pending_functions
    prog = b.program

    err = assert_raises(GBA::LoweringError) { GBA.new.lower(prog) }
    assert_match(/paint/, err.message)
    assert_match(/shared across screen modes/, err.message)
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
    b.emit_pending_functions
    modes = RubyGBA::IR::Modes.resolve(b.program)

    refute_includes modes.scene_funcs, :tick,
                     "a per-frame routine must not be treated as a mode-owning scene"
    assert_includes modes.scene_funcs.map { |n| RubyGBA::IR::Modes.friendly_name(n) }, "a",
                     "a real case_var scene must still be tracked"
  end

  # The full-size regression: an affine title with text, a once_a_frame effect
  # declared ANYWHERE in the program (even in code the title scene never calls),
  # and a plain bitmap play scene after it. Both the title's text and the play
  # scene's undistorted picture must survive — this is the exact shape that broke
  # in examples/pong.rb (a `flash_screen` inside `update_ball`, a func the title
  # screen never reaches, silently erased the title's own text every frame).
  def test_affine_title_with_a_once_a_frame_effect_elsewhere_still_shows_its_text
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      var :state, 0

      func :unrelated do
        flash_screen :red, frames: 4 # never called — presence alone must not break anything
      end

      scene :title do
        screen :rotozoom
        image(:dark, "#" => :blue) { (["########"] * 8).join("\n") }
        tiles :ground, "#" => :dark
        board = background :board, tiles: :ground, map: (["#" * 32] * 32)
        board.scale(1.0)
        draw_text "HI", 100, 20, :white
        pressed(:start).then { set :state, 1 }
      end
      scene(:playing) { clear_screen :black }

      game_loop do
        wait_vblank
        case_var(:state) { when_val 0, :title; when_val 1, :playing }
      end
    end
    b.emit_pending_functions
    prog = b.program

    rom = RubyGBA::ROM.assemble(GBA.new.lower(prog), title: "AFMD", code: "BAFM", maker: "01")

    v = assert_emulator_loads_rom(rom, frames: 10)
    white_shows = (100..112).any? { |x| (20..27).any? { |y| v.pixel_is?(x, y, :white) } }
    assert white_shows, "the affine scene's text should show somewhere in its glyph area"

    v2 = assert_emulator_loads_rom(rom, frames: 10, keys: KEY_START)
    assert v2.black?(0, 0), "the bitmap play scene must not be distorted by a leftover affine matrix"
  end

  # A scene-owned affine background's own per-frame hardware setup (re-uploading its
  # map/control register, since its `background` node sits in the scene body and runs
  # every frame the scene is active) must not reset the rotate/scale matrix back to
  # identity each time. It used to: #emit_affine_background_hardware unconditionally
  # wrote the "no transform" matrix every time it ran, which stomped a growing
  # `scale.approach` right back to 1.0 before the console ever showed it — so a title
  # screen that was supposed to zoom in just sat there, frozen. Checked here by
  # reading a whole scanline back at two points during a scale ramp and asserting
  # it's genuinely different — a frozen matrix would render byte-for-byte the same
  # picture every frame.
  def test_a_scene_owned_affine_backgrounds_scale_keeps_changing
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      var :state, 0
      zoom = var :zoom, 1.0
      scene :title do
        screen :rotozoom
        image(:dark, "#" => :blue) { (["########"] * 8).join("\n") }
        image(:light, "#" => :green) { (["########"] * 8).join("\n") }
        tiles :ground, "#" => :dark, "$" => :light
        checker = (0...32).map { |r| (0...32).map { |c| (r + c).even? ? "#" : "$" }.join }
        board = background :board, tiles: :ground, map: checker
        zoom.approach 4.0, 0.15
        board.scale(zoom)
      end
      game_loop { wait_vblank; case_var(:state) { when_val 0, :title } }
    end
    b.emit_pending_functions
    rom = RubyGBA::ROM.assemble(GBA.new.lower(b.program), title: "ZOOM", code: "BZOM", maker: "01")

    early = assert_emulator_loads_rom(rom, frames: 3)
    later = assert_emulator_loads_rom(rom, frames: 20)
    row_at = ->(v) { (0...240).map { |x| v.pixel_gba(x, 60) } }

    refute_equal row_at.call(early), row_at.call(later),
                 "the checkerboard should look different as it scales up — a frozen matrix renders the same picture every frame"
  end
end
