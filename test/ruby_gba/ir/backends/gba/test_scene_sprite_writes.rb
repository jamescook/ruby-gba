# frozen_string_literal: true

require "test_helper"
require "differential"

# WHERE A SCENE'S MOVING SPRITES ARE WRITTEN FROM. The console composes its picture from a
# table of sprites, and a sprite the game moves has its row of that table written in the gap
# after each frame is drawn. A sprite declared inside a scene is on screen only while that
# scene is, so its row needs writing only on that scene's frames — and the code that writes
# it belongs with its scene rather than in the game loop's own body.
#
# The difference is where the code runs from. The game loop's body is the first thing the
# framework keeps in the console's quick memory, so every scene's writes sitting in it took
# that memory from whatever runs every frame: a file-select screen shown once pushed the
# playing scene out, and the whole of play then ran from the cartridge.
class TestSceneSpriteWrites < Minitest::Test
  include Differential
  include RubyGBA::Console::Hardware

  RED = RubyGBA::Graphics::Color.rgb(31, 0, 0)
  GREEN = RubyGBA::Graphics::Color.rgb(0, 31, 0)

  FRAME = RubyGBA::Cartridge::BuildRecord::FRAME_ROUTINE
  PLAYING_SPRITES = :__sprites_scene_playing
  FILES_SPRITES = :__sprites_scene_files

  private def built(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    builder.program
  end

  # A game of two screens: play, with a hero the game moves, and a file screen with +markers+
  # that slide down. The game walks between them on its own, so both backends see the same
  # frames with no buttons: play until frame 6, the file screen until frame 12, play again.
  private def two_screens(markers:)
    built do
      screen :tiled
      image :hero, width: 16, height: 16, data: Array.new(256, RED)
      image :marker, width: 16, height: 16, data: Array.new(256, GREEN)
      t = var :t, 0
      where = var :where, 0
      scene(:playing) { sprite(:hero, at: [8, 100]).move(:right, by: 1) }
      scene :files do
        markers.times { |i| sprite(:marker, at: [(i * 24) + 8, 8]).move(:down, by: 1) }
      end
      game_loop do
        t.add! 1
        (t == 6).then { where.set! 1 }
        (t == 12).then { where.set! 0 }
        case_var(:where) do
          when_val 0, :playing
          when_val 1, :files
        end
      end
    end
  end

  private def placement_of(program, **opts)
    backend = GBA.new(**opts)
    backend.lower(program)
    backend.iwram_report
  end

  # THE ONE THAT MATTERS. More moving sprites on the file screen add nothing to the game
  # loop's own body: they are written by code of their own.
  def test_a_scenes_moving_sprites_do_not_grow_the_game_loop
    one = placement_of(two_screens(markers: 1)).sizes[FRAME]
    four = placement_of(two_screens(markers: 4)).sizes[FRAME]

    assert_equal one, four, "four moving sprites on the file screen must cost the game loop what one does"
  end

  # ...and that code is a routine the chooser weighs like any other: where there is room, the
  # playing scene's sprites go to the quick memory with the scene that moves them.
  def test_a_scenes_sprite_writes_can_go_to_the_quick_memory
    assert_includes placement_of(two_screens(markers: 4)).funcs, PLAYING_SPRITES
  end

  # With a measured run saying the file screen is cheap, its sprite writes stay in the
  # cartridge and play keeps its place — which is the whole point.
  def test_a_cheap_scenes_sprite_writes_stay_in_the_cartridge
    work = { FRAME => 400, _scene_playing: 900, PLAYING_SPRITES => 300,
             _scene_files: 2, FILES_SPRITES => 2 }
    profile = RubyGBA::Diagnostics::RoutineProfile.new(work: work)
    funcs = placement_of(two_screens(markers: 4), routine_profile: profile).funcs

    assert_includes funcs, PLAYING_SPRITES
    refute_includes funcs, FILES_SPRITES
  end

  # The chooser adds up what each routine will come to once moved, and the game loop now
  # calls the sprite routines on every frame. A call that crosses between the two memories
  # grows, so each of those calls has to be charged for.
  def test_the_game_loop_is_charged_for_the_calls_it_makes_to_them
    backend = GBA.new
    backend.lower(two_screens(markers: 4))
    short = backend.charged_against_emitted.select { |_name, (charged, emitted)| charged < emitted }

    assert_empty short, "came out bigger than charged: #{short}"
  end

  # THE PICTURE DOES NOT CHANGE. The oracle draws every sprite on every frame and knows none of
  # this, so every pixel is compared across both changes of screen: the markers must go when
  # the file screen does, and the hero must come back where the game left him.
  def test_the_console_draws_each_screens_sprites_and_only_those
    [3, 8, 10, 14, 16].each { |f| assert_backends_agree(two_screens(markers: 4), frames: f) }
  end

  def test_the_markers_are_gone_once_play_takes_over_again
    rom = assemble_rom(two_screens(markers: 4), name: "SCENES")
    v = assert_emulator_loads_rom(rom, frames: 10)
    assert_equal 4, v.sprites(:marker).size, "the markers are up on the file screen"

    v.step(8)
    assert_empty v.sprites(:marker), "and gone once play has taken over again"
    refute_empty v.sprites(:hero)
  end
end
