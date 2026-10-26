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
  include VBlank::Console::Hardware

  RED = VBlank::Graphics::Color.rgb(31, 0, 0)
  GREEN = VBlank::Graphics::Color.rgb(0, 31, 0)

  FRAME = VBlank::Cartridge::BuildRecord::FRAME_ROUTINE
  PLAYING_SPRITES = VBlank::Messages::MadeNames.make(:scene_sprites, scene: :playing)
  FILES_SPRITES = VBlank::Messages::MadeNames.make(:scene_sprites, scene: :files)

  private def built(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
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
    profile = VBlank::Diagnostics::RoutineProfile.new(work: work)
    funcs = placement_of(two_screens(markers: 4), routine_profile: profile).funcs

    assert_includes funcs, PLAYING_SPRITES
    refute_includes funcs, FILES_SPRITES
  end

  # A game shaped like a room of an adventure: a pool of +things+ that each pick one of two
  # pictures and one of two lists of colours, declared in the scene the game is played in.
  # The second picture trims smaller than the first, so the things do not all draw alike.
  # A thing is spawned on each of the first passes, and the third is taken away again, so
  # the pool has a gap in it.
  private def cast(things:, spawned: things)
    built do
      screen :tiled
      colors :worn, %i[transparent red green blue]
      colors :faded, %i[transparent blue red green]
      image :tall, width: 16, height: 16, places: Array.new(256, 1), colors: :worn
      image :short, width: 16, height: 16, places: Array.new(256) { |i| i < 128 ? 0 : 2 }, colors: :worn
      made = var :made, 0
      var :where, 0
      scene :playing do
        crowd = pool :thing, x: 0, y: 0, picture: 0, wears: 0, capacity: things, facing: { tall: :tall, short: :short }
        (made < spawned).then do
          crowd.spawn(x: (made * 20) + 4, y: (made * 12) + 4, picture: made % 2, wears: made / 2 % 2)
          made.add! 1
        end
        crowd.each do |thing|
          thing.x.add! 1
          thing.face %i[tall short], showing: thing.picture
          thing.draw_with %i[worn faded], showing: thing.wears
          ((made == spawned) & (thing.index == 2)).then { thing.remove }
        end
      end
      game_loop { case_var(:where) { when_val 0, :playing } }
    end
  end

  # A POOL'S SPRITES ARE ONE WRITE, GONE ROUND. Every sprite of a pool is written the same
  # way, from the same lists, and differs from the next only in which entry it reads and
  # which row of the console's table it writes. So the routine holds the write once and goes
  # round it: a room of forty-five things costs the code a room of twenty does — but for the
  # numbers the round starts from, which take an instruction or two more to load as they get
  # bigger — and twenty cost less than two copies of the write a pool of one gets.
  def test_a_pools_sprites_cost_the_routine_the_same_however_many_there_are
    one, twenty, forty_five = [1, 20, 45].map { |things| placement_of(cast(things: things)).sizes[PLAYING_SPRITES] }

    assert_operator forty_five - twenty, :<=, 16,
                    "forty-five things (#{forty_five} bytes) must cost the routine what twenty do (#{twenty})"
    assert_operator twenty, :<, one * 2, "and twenty (#{twenty}) less than two copies of the one (#{one})"
  end

  # ...and going round it writes what the copies wrote: each thing where it stands, in its
  # own picture and its own colours, the gap a removed thing left closed up, and the places
  # nothing is using hidden.
  def test_a_pool_written_by_one_write_draws_each_thing_as_the_oracle_does
    [2, 5, 9].each { |f| assert_backends_agree(cast(things: 8, spawned: 6), frames: f) }
  end

  # Planks too wide for one of the console's objects, so each is drawn as two standing side by
  # side, in a pool no scene owns — so the frame's own body writes them. +dimmed+ puts small
  # ones in a layer a fade is placed behind, with a post the fade does reach, so the line
  # falls between sprites and each thing kept out has a window of its own to keep the fade
  # off it.
  private def planks(capacity:, dimmed: false)
    built do
      screen :tiled
      layers :world, :ui if dimmed
      image :plank, width: 72, height: 8, data: Array.new(72 * 8) { |i| (i % 72) < 64 ? RED : GREEN }
      image :block, width: 8, height: 8, data: Array.new(64, GREEN)
      made = var :made, 0
      declare = -> { pool :plank, x: 0, y: 0, capacity: capacity, image: dimmed ? :block : :plank }
      layer(:world) { sprite(:block, at: [100, 120]) } if dimmed
      stack = dimmed ? layer(:ui, &declare) : declare.call
      fade :black, 100, under: :ui if dimmed # all the way: the emulator rounds a part fade its own way (see EmulatorBlend)
      game_loop do
        (made < 4).then do
          stack.spawn(x: (made * 30) + 4, y: (made * 20) + 8)
          made.add! 1
        end
        stack.each { |plank| plank.x.add! 1 }
      end
    end
  end

  # The one write covers every object a thing is drawn as, so a thing of two objects is still
  # one thing: the code does not grow with the pool, and each plank stands whole.
  def test_a_pool_of_things_drawn_as_several_objects_is_one_write_and_stands_whole
    few = placement_of(planks(capacity: 5)).sizes[FRAME]
    many = placement_of(planks(capacity: 20)).sizes[FRAME]

    assert_operator many - few, :<=, 16, "twenty planks (#{many} bytes) must cost the frame what five do (#{few})"
    [3, 7].each { |f| assert_backends_agree(planks(capacity: 5), frames: f) }
  end

  # A thing kept out of a placed fade has a window of its own at a place going round one
  # write cannot reach, so those are still written one by one — and still drawn right.
  def test_a_pool_kept_out_of_a_placed_fade_is_still_drawn_right
    [3, 7].each { |f| assert_backends_agree(planks(capacity: 5, dimmed: true), frames: f) }
  end

  # The chooser adds up what each routine will come to once moved, and the game loop now
  # calls the sprite routines on every frame. A call that crosses between the two memories
  # grows, so each of those calls has to be charged for.
  def test_the_game_loop_is_charged_for_the_calls_it_makes_to_them
    backend = GBA.new
    backend.lower(two_screens(markers: 4))
    short = backend.charged_and_emitted_sizes.select { |_name, (charged, emitted)| charged < emitted }

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
