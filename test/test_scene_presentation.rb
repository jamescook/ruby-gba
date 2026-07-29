# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

# Scene-owned presentation: a sprite or HUD element declared inside a scene belongs to
# that scene and is shown only while the scene is the active one — the console hides the
# other scenes' presentation for you. This is what lets a game switch screens (play ->
# game over) without any per-draw visibility flag: belonging to a scene IS the visibility.
#
# The scene machinery it rides on already exists (scene + case_var + a state variable);
# this adds that a scene's declared sprites/HUD are scoped to it. Here a :playing scene
# owns a red block and a :over scene owns a blue block; only the active scene's block
# shows, on the interpreter oracle and on the console.
class TestScenePresentation < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  Builder = RubyGBA::Builder
  Ruby = RubyGBA::IR::Backends::Ruby
  Color = RubyGBA::Color

  RED = Color.resolve(:red)
  BLUE = Color.resolve(:blue)
  WHITE = Color.resolve(:white)

  # Is there a white pixel anywhere in a small box — for finding a HUD glyph without
  # pinning the font's exact pixels.
  def white_in?(screen, x, y, w, h)
    (y...y + h).any? { |py| (x...x + w).any? { |px| screen.pixel(px, py) == WHITE } }
  end

  # A :playing scene owning a red block (top-left), a :over scene owning a blue block
  # (lower-right); START switches playing -> over. Tiled throughout — one display mode.
  def two_scene_program
    b = Builder.new
    b.instance_eval do
      screen :tiled
      var :state, 0
      image(:reddot, "#" => :red) { "########\n" * 8 }   # an 8x8 red block
      image(:bluedot, "#" => :blue) { "########\n" * 8 } # an 8x8 blue block

      scene :playing do
        sprite :reddot, at: [40, 40] # belongs to :playing
        pressed(:start).then { set :state, 1 }
      end
      scene :over do
        sprite :bluedot, at: [100, 100] # belongs to :over
        draw_text "GO", 60, 60, :white  # a HUD banner that belongs to :over
      end

      game_loop do
        wait_vblank
        case_var :state do
          when_val 0, :playing
          when_val 1, :over
        end
      end
    end
    b.emit_pending_functions
    b.program
  end

  # The oracle: while :playing is active only its red block shows; the :over scene's blue
  # block is hidden even though it's declared, because :over isn't the active scene.
  def test_only_the_active_scenes_sprite_shows
    playing = Ruby.new.run(two_scene_program) # no input: stays on :playing
    assert_equal RED, playing.screen.pixel(43, 43), "the playing scene's block shows"
    refute_equal BLUE, playing.screen.pixel(103, 103), "the other scene's block is hidden"
  end

  # Switching scenes switches what's presented: START moves to :over, so the blue block
  # appears and the red one is gone — with no visibility flag in the program.
  def test_switching_scene_switches_the_presentation
    over = Ruby.new.input_each_frame { |_f| [:start] }.run(two_scene_program)
    assert_equal 1, over[:state], "START switched to the :over scene"
    assert_equal BLUE, over.screen.pixel(103, 103), "the over scene's block shows"
    refute_equal RED, over.screen.pixel(43, 43), "the playing scene's block is gone"
  end

  # HUD text is scene-scoped too: the :over scene's banner is declared inside it (the
  # top-level-only rule is relaxed for a scene body) and only shows once :over is active.
  def test_scene_hud_text_shows_only_on_its_scene
    playing = Ruby.new.run(two_scene_program)
    refute white_in?(playing.screen, 58, 58, 24, 12), "the over banner is hidden while playing"

    over = Ruby.new.input_each_frame { |_f| [:start] }.run(two_scene_program)
    assert white_in?(over.screen, 58, 58, 24, 12), "the over banner shows once :over is active"
  end

  # The same scene-gated presentation renders on the console: the red block on the title
  # scene, the blue block after START — proof the GBA lowering honors the scene gate for
  # free (it rides the object's existing per-frame `active` value).
  def test_it_renders_each_scene_on_the_console
    rom = assemble_rom(two_scene_program, name: "SCN")

    title = assert_gemba_loads_rom(rom, frames: 4) # no input: :playing
    assert title.pixel_is?(43, 43, :red), "playing block, got 0x#{format('%04X', title.pixel_gba(43, 43))}"
    refute title.pixel_is?(103, 103, :blue), "over block should be hidden on :playing"

    switched = assert_gemba_loads_rom(rom, frames: 6, keys: KEY_START)
    assert switched.pixel_is?(103, 103, :blue), "over block, got 0x#{format('%04X', switched.pixel_gba(103, 103))}"
  end
end
