# frozen_string_literal: true

require "test_helper"

# Per-scene bitmap<->tiled switching: a game can run one scene as a direct-color
# BITMAP screen (a linear framebuffer — plain draws, software sprites) and another
# as a TILED screen (a tilemap the console composites with hardware sprites), and
# switching scenes flips which display system is live. The classic shape is a
# direct-color bitmap title handing off to a tiled hardware-sprite game.
#
# This pins the model on the reference interpreter (the oracle). The GBA hardware
# realization — reconfiguring DISPCNT / VRAM / OAM on the crossing — is its sibling.
class TestSceneDisplayMode < Minitest::Test
  include RubyGBA::Constants

  RED = Color.resolve(:red)     # the bitmap title's fill
  GREEN = Color.resolve(:green) # the tiled game's hardware sprite
  BLACK = 0                     # an unwritten / wiped pixel

  # A direct-color bitmap title (red) that switches on START to a tiled scene whose
  # hardware sprite (a green 8x8) sits at (100, 76). The title is declared first and
  # the tiled scene second, the natural title->game order.
  def bitmap_to_tiled_program
    b = Builder.new
    b.instance_eval do
      image(:hero, "#" => :green) { "########\n" * 8 }
      screen :bitmap # default: direct-color bitmap
      var :state, 0
      scene :title do
        clear_screen :red
        pressed(:start).then { set :state, 1 }
      end
      scene :play do
        screen :tiled # this scene is a tiled screen
        sprite :hero, at: [100, 76] # a hardware sprite, because this scene is tiled
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

  # With no input the game stays on the bitmap title: the framebuffer shows its red
  # fill everywhere, and the tiled scene's hardware sprite is nowhere (it belongs to
  # the play scene, which is inactive).
  def test_the_bitmap_scene_renders_through_the_framebuffer
    i = Reference.new.run(bitmap_to_tiled_program)
    assert_equal RED, i.screen.pixel(0, 0), "the bitmap title fills the framebuffer red"
    assert_equal RED, i.screen.pixel(103, 79), "the tiled hardware sprite is hidden while the title is active"
  end

  # Holding START switches to the tiled scene: its hardware sprite composites onto
  # the tiled display, and — crucially — the bitmap title's red is gone. The two
  # displays reuse the same video memory, so crossing into tiled stops the bitmap
  # surface being shown; the corner reads as a wiped (black) tiled backdrop, not red.
  def test_switching_to_the_tiled_scene_flips_which_display_presents
    i = Reference.new.input_each_frame { |_f| [:start] }.run(bitmap_to_tiled_program)
    assert_equal GREEN, i.screen.pixel(103, 79), "the tiled scene's hardware sprite renders"
    refute_equal RED, i.screen.pixel(0, 0), "the bitmap title's pixels don't bleed under the tiled scene"
    assert_equal BLACK, i.screen.pixel(0, 0), "crossing into tiled wipes the old bitmap surface"
  end

  # The per-scene mode is decided by what a scene declares, not by which scene was
  # built before it. Here the TILED scene is declared (and built) first, so a leaky
  # global mode would infect the later BITMAP scene and make its sprite a hardware
  # one. Each scene's `sprite` picks its own backend from its own mode: the tiled
  # scene's is a hardware sprite, the bitmap scene's a software one.
  def test_a_scenes_mode_does_not_leak_into_a_later_scene
    tiled_sprite = nil
    bitmap_sprite = nil
    b = Builder.new
    b.instance_eval do
      image(:hero, "#" => :green) { "########\n" * 8 }
      image(:cursor, "#" => :white) { "########\n" * 8 }
      screen :bitmap # default: bitmap
      var :state, 0
      scene :play do
        screen :tiled # tiled, and built first
        tiled_sprite = sprite :hero, at: [100, 76]
      end
      scene :menu do
        # no `screen` here: inherits the bitmap default despite the tiled scene above
        bitmap_sprite = sprite :cursor, at: [10, 10]
      end
      game_loop do
        wait_vblank
        case_var :state do
          when_val 0, :menu
          when_val 1, :play
        end
      end
    end
    b.emit_pending_functions

    assert_instance_of RubyGBA::HardwareSprite, tiled_sprite,
                       "the tiled scene's sprite is a hardware (OAM) sprite"
    assert_instance_of RubyGBA::Sprite, bitmap_sprite,
                       "the bitmap scene's sprite stays a software sprite, even though a tiled scene was built first"
  end

  # A program that crosses the bitmap/tiled boundary lowers to a GBA ROM — the backend
  # switches the whole display per scene (the mode register plus the VRAM/OAM layout),
  # so it no longer refuses the program. (Its behavior on the console is asserted by the
  # gemba test below.)
  def test_a_mixed_bitmap_and_tiled_program_lowers_to_a_rom
    code = GBA.new.lower(bitmap_to_tiled_program)
    assert_operator code.bytesize, :>, 0
  end

  # The same crossing on real hardware (gemba): the console shows the direct-color
  # bitmap title, and after START it reconfigures the whole display — the mode
  # register, the sprite table, the VRAM the tiles/sprites live in — so the tiled
  # scene's hardware sprite renders and the bitmap title's red is gone.
  def test_the_switch_flips_the_display_on_the_console
    rom = ROM.assemble(GBA.new.lower(bitmap_to_tiled_program), title: "MIX", code: "BMIX", maker: "01")

    title = assert_gemba_loads_rom(rom, frames: 4) # no input: the Mode 3 bitmap title
    assert title.red?(0, 0),
           "the bitmap title is red on the console, got 0x#{format('%04X', title.pixel_gba(0, 0))}"

    play = assert_gemba_loads_rom(rom, frames: 8, keys: KEY_START) # START -> the tiled scene
    assert play.green?(103, 79),
           "the tiled hardware sprite renders after the switch, got 0x#{format('%04X', play.pixel_gba(103, 79))}"
    refute play.red?(0, 0),
           "the bitmap title's red is gone once the display crosses into tiled, got 0x#{format('%04X', play.pixel_gba(0, 0))}"
  end
end
