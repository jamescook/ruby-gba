# frozen_string_literal: true

require "test_helper"
require "differential"

# THE TESTS OF vblank/dsl/test_sprite_draws_with.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# A SPRITE THAT DRAWS WITH A DIFFERENT SET OF COLOURS while the game runs — a character that
# cannot be hit flashing warm, a poisoned enemy turning green. Its picture does not change:
# every pixel keeps its place in the sprite's own list of colours, and only the colours those
# places show are swapped for the ones in another list.
class TestSpriteDrawsWithOnTheAdvance < Minitest::Test
  include Differential

  OWN = [:transparent, :red, :green].freeze
  HURT = [:transparent, :yellow, :white].freeze

  # An 8x8 ship, left half the first colour of its list and right half the second, so a
  # swapped colour shows at a known place.
  SHIP = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  private def program(&game)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      colors :hurt, HURT
      ship = sprite :ship, at: [40, 40]
      game_loop { instance_exec(ship, &game) }
    end
    builder.finalize_program
    builder.program
  end

  # A picture the game paints from a list keeps its pixels as places, so another list swaps
  # its colours by place the same way. A save file's name wears its panel's colours like this.
  private def painted_program
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :ink, OWN
      colors :hurt, HURT
      canvas = list :canvas, capacity: 32, width: :byte
      repeat(8) { [0x11, 0x11, 0x22, 0x22].each { |two_pixels| canvas.push two_pixels } }
      tag = image :tag, from: canvas, width: 8, height: 8, colors: :ink
      tag.changed
      ship = sprite :tag, at: [40, 40]
      step = var :step, 0
      game_loop do
        ship.draw_with [:ink, :hurt], showing: step
        step.add! 1
      end
    end
    builder.finalize_program
    builder.program
  end

  # A sprite told to draw with another list before its picture is first painted: the picture is
  # blank to start with, and once it is painted it shows the other list's colours, by the
  # places it holds then.
  private def painted_late_program
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :ink, OWN
      colors :hurt, HURT
      canvas = list :canvas, capacity: 32, width: :byte
      repeat(8) { [0x11, 0x11, 0x22, 0x22].each { |two_pixels| canvas.push two_pixels } }
      tag = image :tag, from: canvas, width: 8, height: 8, colors: :ink
      ship = sprite :tag, at: [40, 40]
      pass = var :pass, 0
      game_loop do
        ship.draw_with :hurt
        pass.add! 1
        (pass == 3).then { tag.changed }
      end
    end
    builder.finalize_program
    builder.program
  end

  # --- picked by a number the game works out ---

  # A pulse: a counter walks through two lists and past them, and the ship steps right on
  # the same frames, so a colour a frame early or late shows against the position.
  private def pulse_program
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      colors :warm, [:transparent, :yellow, :white]
      colors :hot, [:transparent, :orange, :blue]
      ship = sprite :ship, at: [40, 40]
      step = var :step, 0
      game_loop do
        ship.draw_with [:warm, :hot], showing: step
        ship.x.add! 1
        step.add! 1
      end
    end
    builder.finalize_program
    builder.program
  end

  # The colour of the ship's left edge, wherever it has got to.
  private def left_edge_color(frames)
    i = game_player.run(pulse_program, frames: frames)
    i.screen.pixel((40..).find { |col| i.screen.pixel(col, 41) != 0 }, 41)
  end

  # The console writes a sprite's table entry four ways — upright in one pose, upright in a
  # pose the game picks, turning, and poses that came out different sizes (a mirrored one
  # among them) — and a picture too big for one object is several entries. Each carries the
  # colours.
  private def every_draw_program
    long = Array.new(96 * 16) { |i| (i % 96) < 48 ? :red : :green }
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :floor, "#" => :blue do
        (["########"] * 8).join("\n")
      end
      tiles :ground, "#" => :floor
      background :field, tiles: :ground, map: Array.new(20, "#" * 30)
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      image :long, width: 96, height: 16, data: long, colors: OWN
      image :lean, width: 16, height: 16, data: Array.new(256) { |i| (i % 16) < 3 && i / 16 < 12 ? :red : :transparent },
                   transparent: true, colors: OWN
      image :ship_turned, width: 8, height: 8, data: Array.new(64) { |i| (i / 8) < 4 ? :red : :green }, colors: OWN
      colors :hurt, HURT
      turning = sprite :ship, at: [20, 20]
      big = sprite :long, at: [40, 100]
      facing = sprite :lean, at: [140, 20], facing: { right: :lean, left: mirror(:lean) }
      flapping = sprite :flap, at: [200, 60], frames: [:ship, :ship_turned], rate: 1
      game_loop do
        turning.face_angle 45
        facing.face :left
        [turning, big, facing, flapping].each { |thing| thing.draw_with :hurt }
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_every_way_the_console_draws_a_sprite_carries_the_colors
    assert_backends_agree(every_draw_program, frames: 3)
  end

  # --- every instance of a pool on its own ---

  # Two ships in a pool, and only the one on the right is hurt. After a few frames the hurt
  # one is removed and a new one spawned into its slot, which must not inherit its colours.
  private def pool_program(respawn_at: nil)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      colors :hurt, HURT
      ships = pool :ship, x: 0, y: 0, capacity: 2, image: :ship
      ships.spawn x: 40, y: 40
      ships.spawn x: 80, y: 40
      frame = var :frame, 0
      game_loop do
        frame.add! 1
        ships.each do |ship|
          (frame == 1).then { (ship.x == 80).then { ship.draw_with :hurt } }
          (frame == respawn_at).then { (ship.x == 80).then { ship.remove } } if respawn_at
        end
        (frame == respawn_at).then { ships.spawn x: 80, y: 40 } if respawn_at
      end
    end
    builder.finalize_program
    builder.program
  end

  # --- friendly errors ---

  private def built(&block)
    VBlank.build("COLORS", console: :gba, code: "BCOL", maker: "01", out: StringIO.new, err: StringIO.new, &block)
  end

  private def refused(error = ArgumentError, &block)
    assert_raises(error) { built(&block) }
  end

  # SIXTEEN IS EXACTLY ENOUGH: the ship's own colours and fifteen lists, one group each, with
  # nothing left over. The first group of the table is one of the sixteen. Its first entry is
  # never drawn, as in every group, so sprites can have it.
  #
  # The ship walks through every list, a new one each pass, so whichever of them landed in
  # the first group is shown. The screen has no scenery, so everywhere but the ship is the
  # backdrop, which is a colour of the scenery's table and has to stay as it was. Each list
  # is written with magenta first, the place that means see-through: that is the colour
  # sitting on the first entry of the sprites' table, where nothing draws it.
  private def ship_drawn_with_fifteen_lists
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      names = (1..15).map { |n| colors :"pulse#{n}", [:magenta, VBlank::Graphics::Color.rgb(n * 2, 31 - n, n), :white] }
      ship = sprite :ship, at: [40, 40]
      step = var :step, -1
      game_loop do
        ship.draw_with names, showing: step
        step.add! 1
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_a_sprite_and_fifteen_lists_take_all_sixteen_groups
    walking = ship_drawn_with_fifteen_lists
    # Pass 1 shows the ship's own colours and passes 2 to 16 a list each.
    (2..17).each { |frames| assert_backends_agree(walking, frames: frames) }

    console = assert_emulator_loads_rom(assemble_rom(walking, name: "SIXTEEN"), frames: 2)
    worn = Array.new(17) do
      console.step
      console.sprites(:ship).first.palette
    end

    assert_equal 16, worn.uniq.size, "the ship wore sixteen different groups"
    assert_equal Color.resolve(:black), console.pixel_gba(120, 120), "the colour behind everything is as it was"
  end

  # --- scenes take turns with the groups ---

  # THE SIXTEEN GROUPS ARE ONE SCENE'S, NOT THE WHOLE GAME'S, the way a scene's pictures and
  # scenery already are: two scenes are never on screen together, so each can have the groups
  # to itself. Here each scene's ship draws with one of nine lists besides its own — ten groups
  # a scene, twenty for the game. The ship shows the last list, so a group another scene took
  # over shows up as the wrong colour, and coming back to the first scene is read too.
  TURNS = 9
  PICKED = TURNS - 1
  SECOND_SCENE_AT = 6
  FIRST_SCENE_AGAIN_AT = 12

  private def shade(scene, n) = scene == :one ? VBlank::Graphics::Color.rgb(n + 1, 0, 0) : VBlank::Graphics::Color.rgb(0, n + 1, 0)

  private def two_scenes_of_many_lists
    turns = TURNS
    shades = %i[one two].to_h { |scene| [scene, (0...turns).map { |n| shade(scene, n) }] }
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      step = var :step, PICKED
      %i[one two].each do |scene_name|
        scene(scene_name) do
          names = shades[scene_name].each_with_index.map { |c, n| colors :"#{scene_name}_#{n}", [:transparent, c, :white] }
          ship = sprite :ship, at: [40, 40]
          ship.draw_with names, showing: step
        end
      end
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick.add! 1
        (tick > SECOND_SCENE_AT).then { state.set! 1 }
        (tick > FIRST_SCENE_AGAIN_AT).then { state.set! 0 }
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_each_scene_has_the_sixteen_groups_to_itself
    prog = two_scenes_of_many_lists
    seen = [SECOND_SCENE_AT, FIRST_SCENE_AGAIN_AT, FIRST_SCENE_AGAIN_AT + 6].map do |frames|
      game_player.run(prog, frames: frames).screen.pixel(41, 41)
    end

    assert_equal [shade(:one, PICKED), shade(:two, PICKED), shade(:one, PICKED)], seen
  end

  # ...UNDER A TINT, and beside a sprite every scene shows. A tiled screen tints by moving the
  # colour tables themselves, and a tint held steady is not walked again — so a scene's colours
  # sent as it takes over have to go in already tinted, or its sprites arrive at full colour in
  # the middle of a red screen. The badge belongs to no scene and has to keep its colours
  # whichever scene's groups are in.
  private def tinted_scenes
    turns = TURNS
    shades = %i[one two].to_h { |scene| [scene, (0...turns).map { |n| shade(scene, n) }] }
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      image :badge, width: 8, height: 8, data: Array.new(64, :blue), colors: %i[transparent blue]
      sprite :badge, at: [100, 40]
      step = var :step, PICKED
      %i[one two].each do |scene_name|
        scene(scene_name) do
          names = shades[scene_name].each_with_index.map { |c, n| colors :"#{scene_name}_#{n}", [:transparent, c, :white] }
          ship = sprite :ship, at: [40, 40]
          ship.draw_with names, showing: step
        end
      end
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tint :red, 50
        tick.add! 1
        (tick > SECOND_SCENE_AT).then { state.set! 1 }
        (tick > FIRST_SCENE_AGAIN_AT).then { state.set! 0 }
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_a_scene_arriving_under_a_tint_is_tinted_and_the_badge_keeps_its_colors
    [SECOND_SCENE_AT, FIRST_SCENE_AGAIN_AT, FIRST_SCENE_AGAIN_AT + 6].each do |frames|
      assert_backends_agree(tinted_scenes, frames: frames)
    end
  end

  def test_the_console_gives_each_scene_the_groups_in_turn
    prog = two_scenes_of_many_lists
    [SECOND_SCENE_AT, FIRST_SCENE_AGAIN_AT, FIRST_SCENE_AGAIN_AT + 6].each do |frames|
      assert_backends_agree(prog, frames: frames)
    end
  end
end
