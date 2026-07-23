# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Per-scene display mode: a game can run different scenes in different display
# modes, switching the hardware as each scene takes over. The common shape is a
# colorful direct-color title (Mode 3, no tear risk because it's static) and a
# heavy-redraw gameplay scene in tear-proof double buffering (Mode 4). A scene
# declares its mode with a `display` at its top; the framework handles the switch.
#
# Both scenes must render correctly on the console, which means the mode transition
# (Mode 3 -> Mode 4) has to actually happen: the palette is uploaded, the pages are
# set up, and the flip only runs while the buffered scene is live.
class TestPerSceneMode < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  GBA = RubyGBA::IR::Backends::GBA
  ROM = RubyGBA::ROM
  Color = RubyGBA::Color

  # A direct-color (Mode 3) title in red; START switches to a double-buffered
  # (Mode 4) play scene showing a blue field with a green cell.
  def mixed_program
    b = Builder.new
    b.instance_eval do
      display :bitmap # default: direct-color Mode 3
      var :state, 0
      scene :title do
        clear_screen :red
        pressed(:start).then { set :state, 1 }
      end
      scene :play do
        display :bitmap, buffered: true # this scene is double-buffered
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
    red = Ruby.new.run(mixed_program) # no input: stays on the title
    assert_equal Color.resolve(:red), red.screen.pixel(0, 0)

    playing = Ruby.new.input_each_frame { |_f| [:start] }.run(mixed_program)
    assert_equal Color.resolve(:blue), playing.screen.pixel(0, 0)
    assert_equal Color.resolve(:green), playing.screen.pixel(103, 79)
  end

  # The direct-color title renders on the console (Mode 3, 15-bit color).
  def test_the_direct_color_title_renders_on_the_console
    rom = ROM.assemble(GBA.new.lower(mixed_program), title: "MIX", code: "BMIX", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 4) # no input: the Mode 3 title
    assert v.red?(0, 0), "the direct-color title should be red, got 0x#{format('%04X', v.pixel_gba(0, 0))}"
  end

  # After START, the game switches into the buffered scene, which must render
  # through the auto palette — proof the Mode 3 -> Mode 4 transition works.
  def test_the_buffered_scene_renders_after_the_switch
    rom = ROM.assemble(GBA.new.lower(mixed_program), title: "MIX", code: "BMIX", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 8, keys: KEY_START)
    assert v.blue?(0, 0), "the buffered play field should be blue, got 0x#{format('%04X', v.pixel_gba(0, 0))}"
    assert v.green?(103, 79), "the buffered green cell should render, got 0x#{format('%04X', v.pixel_gba(103, 79))}"
  end

  # A drawing routine reached from scenes of different modes can't be lowered both
  # ways — that's a friendly build error, not a silently-wrong screen.
  def test_a_draw_helper_shared_across_modes_is_a_friendly_error
    b = Builder.new
    b.instance_eval do
      display :bitmap
      var :state, 0
      func :paint do
        clear_screen :white
      end
      scene :a do
        call :paint # direct
      end
      scene :b do
        display :bitmap, buffered: true
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
    assert_match(/shared across display modes/, err.message)
  end
end
