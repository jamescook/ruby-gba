# frozen_string_literal: true

require "test_helper"
require "differential"

# A `sprite` on a bitmap screen DECLARED INSIDE A SCENE: it is painted while its scene is the
# one running, leaves no trail as it moves, and comes off the picture when another scene
# takes over — the promises a sprite declared above the game loop already keeps.
#
# Each test builds a blue field with a red 8x8 block, plays it on the interpreter and on the
# console, checks the two pictures are the same picture, and then counts colours: one block
# of red is one sprite, more is a trail, none is a sprite that left.
class TestSceneSprite < Minitest::Test
  runs_on :reference

  include Differential

  SIDE = 8
  BLOCK = ("########\n" * SIDE).freeze
  START = [40, 40].freeze

  PLAY = 0
  REST = 1

  # A game of two scenes on a blue field, picked by :state, with a counter of the passes so
  # far. The block declares the scenes and is handed both variables. +first+ runs at the top
  # of every pass, before the scene is picked.
  private def scenes_program(first: nil, &scenes)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image(:block, "#" => :red) { BLOCK }
      image(:other, "#" => :green) { BLOCK }
      clear_screen :blue
      state = var :state, PLAY
      step = var :step, 0
      instance_exec(state, step, &scenes)
      game_loop do
        instance_exec(state, step, &first) if first
        case_var(:state) do
          when_val PLAY, :play
          when_val REST, :rest
        end
        step.add! 1
      end
    end
    b.finalize_program
    b.program
  end

  # How many pixels of each colour the picture holds after +frames+ passes, once both
  # backends have been seen to draw the same picture.
  private def colors_after(prog, frames)
    oracle, console, = backend_pictures(prog, frames: frames, name: "SCNSPR")
    bad = mismatched_pixels(oracle, console)
    assert_empty bad.first(5), "the console drew a different picture at #{bad.length} pixels"
    %i[red green blue].to_h { |color| [color, oracle.count(Color.resolve(color))] }
  end

  ONE = SIDE * SIDE
  FIELD = 240 * 160

  def test_a_sprite_declared_inside_a_scene_leaves_no_trail
    prog = scenes_program do |_state, _step|
      scene(:play) { sprite(:block, at: START).move :right, by: 4 }
      scene(:rest) {}
    end

    seen = colors_after(prog, 8)

    assert_equal ONE, seen[:red], "one block of red is one sprite; more is a trail"
    assert_equal FIELD - ONE, seen[:blue], "the field it passed over is put back"
  end

  def test_it_comes_off_the_picture_when_another_scene_takes_over
    prog = scenes_program do |state, step|
      scene(:play) do
        sprite(:block, at: START).move :right, by: 4
        (step == 3).then { state.set! REST }
      end
      scene(:rest) {}
    end

    seen = colors_after(prog, 8)

    assert_equal 0, seen[:red], "the sprite belongs to the scene that left"
    assert_equal FIELD, seen[:blue], "and the field under it is put back"
  end

  # The state changed at the top of the pass, after the sprite was drawn for that frame and
  # before the next scene's first pass.
  def test_it_comes_off_when_the_state_changes_before_the_scene_is_picked
    leave = proc { |state, step| (step == 3).then { state.set! REST } }
    prog = scenes_program(first: leave) do |_state, _step|
      scene(:play) { sprite(:block, at: START).move :right, by: 4 }
      scene(:rest) {}
    end

    seen = colors_after(prog, 8)

    assert_equal 0, seen[:red]
    assert_equal FIELD, seen[:blue]
  end

  def test_it_is_painted_again_when_its_scene_comes_back
    prog = scenes_program do |state, step|
      scene(:play) do
        sprite(:block, at: START).move :right, by: 4
        (step == 3).then { state.set! REST }
      end
      scene(:rest) { (step == 6).then { state.set! PLAY } }
    end

    seen = colors_after(prog, 12)

    assert_equal ONE, seen[:red], "one sprite, and no copy left where it stood when its scene went"
    assert_equal FIELD - ONE, seen[:blue]
  end

  # Each scene's sprite stands where the other's does, so a sprite painted a frame early or
  # taken off a frame late would be remembered under the other one and put back later.
  def test_two_scenes_take_turns_with_the_same_spot
    prog = scenes_program do |state, step|
      scene(:play) do
        sprite :block, at: START
        (step == 3).then { state.set! REST }
      end
      scene(:rest) do
        sprite(:other, at: START).move :down, by: 2
        (step == 7).then { state.set! PLAY }
      end
    end

    seen = colors_after(prog, 12)

    assert_equal ONE, seen[:red]
    assert_equal 0, seen[:green], "the other scene's sprite went with its scene"
    assert_equal FIELD - ONE, seen[:blue]
  end

  # Two sprites that overlap and then part: where they lay over each other, each remembers
  # the other's pixels, and putting them back in the wrong order leaves some behind.
  def test_two_sprites_of_one_scene_overlap_and_part_cleanly
    prog = scenes_program do |_state, _step|
      scene(:play) do
        sprite(:block, at: START).move :right, by: 3
        sprite(:other, at: [START[0] + 4, START[1] + 4]).move :down, by: 3
      end
      scene(:rest) {}
    end

    seen = colors_after(prog, 8)

    assert_equal ONE, seen[:red]
    assert_equal ONE, seen[:green]
    assert_equal FIELD - (2 * ONE), seen[:blue]
  end

  # A sprite every scene shows, declared above the loop, crossing a scene's sprite.
  def test_a_scenes_sprite_and_one_declared_above_the_loop_part_cleanly
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image(:block, "#" => :red) { BLOCK }
      image(:other, "#" => :green) { BLOCK }
      clear_screen :blue
      var :state, PLAY
      shared = sprite :other, at: [START[0] + 4, START[1] + 4]
      scene(:play) { sprite(:block, at: START).move :right, by: 3 }
      game_loop do
        shared.move :down, by: 3
        case_var(:state) { when_val PLAY, :play }
      end
    end
    b.finalize_program

    seen = colors_after(b.program, 8)

    assert_equal ONE, seen[:red]
    assert_equal ONE, seen[:green]
    assert_equal FIELD - (2 * ONE), seen[:blue]
  end

  def test_a_scenes_sprite_hides_and_shows
    prog = scenes_program do |_state, step|
      scene(:play) do
        hero = sprite :block, at: START
        (step == 2).then { hero.hide }
        (step == 5).then { hero.show }
      end
      scene(:rest) {}
    end

    assert_equal 0, colors_after(prog, 5)[:red], "hidden, it is off the picture"
    assert_equal ONE, colors_after(prog, 9)[:red], "shown again, it is back"
    assert_equal FIELD - ONE, colors_after(prog, 9)[:blue]
  end

  def test_a_scenes_sprite_can_start_hidden
    prog = scenes_program do |_state, step|
      scene(:play) do
        hero = sprite :block, at: START, shown: false
        (step == 4).then { hero.show }
      end
      scene(:rest) {}
    end

    assert_equal 0, colors_after(prog, 4)[:red]
    assert_equal ONE, colors_after(prog, 8)[:red]
  end

  # A scene that paints its own field on its first pass. Its sprite must not be on the
  # picture before that, or it remembers the last scene's field and puts a square of it back.
  def test_a_scene_paints_its_field_before_its_sprite_is_drawn
    prog = scenes_program do |state, step|
      scene(:play) { (step == 3).then { state.set! REST } }
      scene(:rest) do
        (step == 4).then { clear_screen :green }
        sprite(:block, at: START).move :right, by: 4
      end
    end

    seen = colors_after(prog, 9)

    assert_equal ONE, seen[:red]
    assert_equal FIELD - ONE, seen[:green], "the new field is whole"
    assert_equal 0, seen[:blue], "no square of the last scene's field came back"
  end

  # The same hand-over the other way round: the state changes at the top of the pass, so the
  # leaving scene's sprite was drawn for that frame, and the new scene paints over it.
  def test_a_scene_paints_its_field_over_the_last_scenes_sprite
    leave = proc { |state, step| (step == 3).then { state.set! REST } }
    prog = scenes_program(first: leave) do |_state, step|
      scene(:play) { sprite :block, at: START }
      scene(:rest) { (step == 3).then { clear_screen :green } }
    end

    seen = colors_after(prog, 8)

    assert_equal FIELD, seen[:green], "nothing the sprite remembered was put back over the new field"
  end

  FLOOR = ([("#." * 15)] * 20).freeze

  # A game whose second scene is drawn from tiles. A tiled screen keeps its tile pictures in
  # the same video memory a painted screen keeps its pixels in, so a software sprite painted
  # or rubbed out while the tiled scene is up writes into the tiles.
  private def mixed_program(&play)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image(:block, "#" => :red) { BLOCK }
      image(:brick, "#" => :green, "." => :white) { "#.#.#.#.\n.#.#.#.#\n" * 4 }
      image(:slab, "#" => :white) { BLOCK }
      tiles :set, "#" => :brick, "." => :slab
      clear_screen :blue
      state = var :state, PLAY
      step = var :step, 0
      fresh = var :fresh, 0
      scene(:play) do
        (fresh == 1).then do
          clear_screen :blue
          fresh.set! 0
        end
        hero = sprite :block, at: [0, 0]
        instance_exec(hero, step, &play) if play
      end
      scene(:rest) do
        screen :tiled
        background :floor, tiles: :set, map: FLOOR
        (step == 7).then do
          state.set! PLAY
          fresh.set! 1
        end
      end
      game_loop do
        (step == 3).then { state.set! REST }
        case_var(:state) do
          when_val PLAY, :play
          when_val REST, :rest
        end
        step.add! 1
      end
    end
    b.finalize_program
    b.program
  end

  def test_handing_over_to_a_tiled_scene_leaves_its_picture_whole
    oracle, console, = backend_pictures(mixed_program, frames: 6, console_frames: 9, name: "SCNMIX")

    assert_empty mismatched_pixels(oracle, console).first(5), "the sprite wrote into the tiled scene's memory"
    assert_equal 0, oracle.count(Color.resolve(:red)), "and it is not on the tiled screen"
  end

  # The sprite steps aside once it is back, so anything it remembered from the frame its
  # scene took over would be left showing where it stood.
  def test_coming_back_from_a_tiled_scene_paints_the_sprite_on_the_new_field
    prog = mixed_program { |hero, step| (step == 10).then { hero.move :right, by: 16 } }
    oracle, console, = backend_pictures(prog, frames: 14, console_frames: 17, name: "SCNMIX")

    assert_empty mismatched_pixels(oracle, console).first(5)
    assert_equal ONE, oracle.count(Color.resolve(:red))
    assert_equal FIELD - ONE, oracle.count(Color.resolve(:blue)), "nothing of the tiled screen was put back"
  end

  # The same two scenes with the red sprite declared ABOVE the loop, so it belongs to every
  # scene. It is a painted-screen sprite all the same, and the tiled scene has no picture for
  # it to be painted into. The block runs at the end of every pass, handed the sprite.
  private def shared_sprite_program(shown: true, &each_pass)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image(:block, "#" => :red) { BLOCK }
      image(:brick, "#" => :green, "." => :white) { "#.#.#.#.\n.#.#.#.#\n" * 4 }
      image(:slab, "#" => :white) { BLOCK }
      tiles :set, "#" => :brick, "." => :slab
      clear_screen :blue
      shared = sprite :block, at: [0, 0], shown: shown
      state = var :state, PLAY
      step = var :step, 0
      fresh = var :fresh, 0
      scene(:play) do
        (fresh == 1).then do
          clear_screen :blue
          fresh.set! 0
        end
      end
      scene(:rest) do
        screen :tiled
        background :floor, tiles: :set, map: FLOOR
        (step == 7).then do
          state.set! PLAY
          fresh.set! 1
        end
      end
      game_loop do
        (step == 3).then { state.set! REST }
        case_var(:state) do
          when_val PLAY, :play
          when_val REST, :rest
        end
        instance_exec(shared, step, &each_pass) if each_pass
        step.add! 1
      end
    end
    b.finalize_program
    b.program
  end

  VIDEO_MEMORY = 0x0600_0000
  RED_PIXEL = 0x001F

  # The first row of a sprite at the top-left corner, as the console's video memory holds it
  # after +frames+: eight pixels on a painted screen, and on a tiled one the start of the
  # tile pictures, which a sprite painted there would write over.
  private def top_left_of_video_memory(prog, frames)
    v = assert_emulator_loads_rom(ROM.assemble(GBA.new.lower(prog), title: "SCNMEM"), frames: frames)
    Array.new(SIDE) { |pixel| v.mem16(VIDEO_MEMORY + (pixel * 2)) }
  end

  def test_a_sprite_declared_above_the_loop_stays_off_a_tiled_scene
    prog = shared_sprite_program
    oracle, console, = backend_pictures(prog, frames: 6, console_frames: 9, name: "SCNMIX")

    assert_empty mismatched_pixels(oracle, console).first(5)
    assert_equal 0, oracle.count(Color.resolve(:red)), "the tiled scene has no picture to paint it into"
    refute_equal [RED_PIXEL] * SIDE, top_left_of_video_memory(prog, 9),
                 "the sprite was painted into the memory the tiled scene keeps its tiles in"
  end

  def test_a_sprite_declared_above_the_loop_comes_back_with_the_painted_scene
    prog = shared_sprite_program { |shared, step| (step == 10).then { shared.move :right, by: 16 } }
    oracle, console, = backend_pictures(prog, frames: 14, console_frames: 17, name: "SCNMIX")

    assert_empty mismatched_pixels(oracle, console).first(5)
    assert_equal ONE, oracle.count(Color.resolve(:red))
    assert_equal FIELD - ONE, oracle.count(Color.resolve(:blue)), "nothing of the tiled screen was put back"
  end

  # `show` paints a sprite on the spot, and the tiled scene is up when this one is shown.
  def test_a_sprite_shown_while_a_tiled_scene_is_up_waits_for_a_painted_one
    prog = shared_sprite_program(shown: false) { |shared, step| (step == 5).then { shared.show } }

    refute_equal [RED_PIXEL] * SIDE, top_left_of_video_memory(prog, 9), "shown, it was painted into the tiles"
    oracle, console, = backend_pictures(prog, frames: 14, console_frames: 17, name: "SCNMIX")
    assert_empty mismatched_pixels(oracle, console).first(5)
    assert_equal ONE, oracle.count(Color.resolve(:red)), "and it is there once a painted scene is back"
  end

  # Any routine's body is built after the game loop, not only a scene's.
  def test_a_sprite_declared_inside_a_func_leaves_no_trail
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      image(:block, "#" => :red) { BLOCK }
      clear_screen :blue
      func(:walk) { sprite(:block, at: START).move :right, by: 4 }
      game_loop { call :walk }
    end
    b.finalize_program

    seen = colors_after(b.program, 8)

    assert_equal ONE, seen[:red]
    assert_equal FIELD - ONE, seen[:blue]
  end
end
