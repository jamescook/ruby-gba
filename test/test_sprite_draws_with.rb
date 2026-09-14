# frozen_string_literal: true

require "test_helper"
require "differential"

# A SPRITE THAT DRAWS WITH A DIFFERENT SET OF COLOURS while the game runs — a character that
# cannot be hit flashing warm, a poisoned enemy turning green. Its picture does not change:
# every pixel keeps its place in the sprite's own list of colours, and only the colours those
# places show are swapped for the ones in another list.
class TestSpriteDrawsWith < Minitest::Test
  include Differential

  OWN = [:transparent, :red, :green].freeze
  HURT = [:transparent, :yellow, :white].freeze

  # An 8x8 ship, left half the first colour of its list and right half the second, so a
  # swapped colour shows at a known place.
  SHIP = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }.freeze

  def program(&game)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      colors :hurt, HURT
      ship = sprite :ship, at: [40, 40]
      game_loop { instance_exec(ship, &game) }
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_sprite_told_to_draw_with_other_colors_shows_them
    i = Reference.new.run(program { |ship| ship.draw_with :hurt }, frames: 2)

    assert_equal Color.resolve(:yellow), i.screen.pixel(41, 41), "the first place of the list"
    assert_equal Color.resolve(:white), i.screen.pixel(45, 41), "and the second"
  end

  def test_the_console_draws_the_other_colors_too
    assert_backends_agree(program { |ship| ship.draw_with :hurt }, frames: 2)
  end

  # Art drawn in characters takes a list too, so a hand-drawn sprite can be recoloured.
  def test_a_picture_drawn_in_characters_can_be_given_its_list
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, "." => :transparent, "#" => :red, "=" => :green, colors: OWN do
        (["####===="] * 8).join("\n")
      end
      colors :hurt, HURT
      ship = sprite :ship, at: [40, 40]
      game_loop { ship.draw_with :hurt }
    end
    builder.emit_pending_functions
    i = Reference.new.run(builder.program, frames: 2)

    assert_equal Color.resolve(:yellow), i.screen.pixel(41, 41)
    assert_equal Color.resolve(:white), i.screen.pixel(45, 41)
  end

  # --- picked by a number the game works out ---

  # A pulse: a counter walks through two lists and past them, and the ship steps right on
  # the same frames, so a colour a frame early or late shows against the position.
  def pulse_program
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
        ship.x.add 1
        step.add 1
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  # The colour of the ship's left edge, wherever it has got to.
  def left_edge_color(frames)
    i = Reference.new.run(pulse_program, frames: frames)
    i.screen.pixel((40..).find { |col| i.screen.pixel(col, 41) != 0 }, 41)
  end

  def test_a_number_picks_one_of_several_lists_and_past_them_is_the_sprites_own
    colors = (1..4).map { |frames| left_edge_color(frames) }

    # The first frame is drawn before the game loop has said anything.
    assert_equal %i[red yellow orange red].map { |name| Color.resolve(name) }, colors
  end

  def test_the_console_changes_colors_on_the_frame_the_sprite_moves
    (1..4).each { |frames| assert_backends_agree(pulse_program, frames: frames) }
  end

  def test_a_sprite_told_its_own_colors_goes_back_to_them
    i = Reference.new.run(program do |ship|
      (ship.x == 40).then { ship.draw_with :hurt }.else { ship.draw_with :own }
      ship.x.set 41
    end, frames: 4)

    assert_equal Color.resolve(:red), i.screen.pixel(42, 41)
  end

  # The console writes a sprite's table entry four ways — upright in one pose, upright in a
  # pose the game picks, turning, and poses that came out different sizes (a mirrored one
  # among them) — and a picture too big for one object is several entries. Each carries the
  # colours.
  def every_draw_program
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
    builder.emit_pending_functions
    builder.program
  end

  def test_every_way_the_console_draws_a_sprite_carries_the_colors
    assert_backends_agree(every_draw_program, frames: 3)
  end

  # --- every instance of a pool on its own ---

  # Two ships in a pool, and only the one on the right is hurt. After a few frames the hurt
  # one is removed and a new one spawned into its slot, which must not inherit its colours.
  def pool_program(respawn_at: nil)
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
        frame.add 1
        ships.each do |ship|
          (frame == 1).then { (ship.x == 80).then { ship.draw_with :hurt } }
          (frame == respawn_at).then { (ship.x == 80).then { ship.remove } } if respawn_at
        end
        (frame == respawn_at).then { ships.spawn x: 80, y: 40 } if respawn_at
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_each_instance_of_a_pool_draws_with_its_own_choice
    i = Reference.new.run(pool_program, frames: 3)

    assert_equal Color.resolve(:red), i.screen.pixel(41, 41), "the ship left alone"
    assert_equal Color.resolve(:yellow), i.screen.pixel(81, 41), "the hurt one"
  end

  def test_an_instance_spawned_into_a_hurt_ones_slot_starts_in_its_own_colors
    i = Reference.new.run(pool_program(respawn_at: 3), frames: 5)

    assert_equal Color.resolve(:red), i.screen.pixel(81, 41)
  end

  def test_the_console_draws_a_pools_instances_the_same
    assert_backends_agree(pool_program, frames: 3)
    assert_backends_agree(pool_program(respawn_at: 3), frames: 5)
  end

  # --- friendly errors ---

  def built(&block)
    RubyGBA.build("COLORS", code: "BCOL", maker: "01", out: StringIO.new, err: StringIO.new, &block)
  end

  def refused(error = ArgumentError, &block)
    assert_raises(error) { built(&block) }
  end

  def test_drawing_with_a_list_never_declared_is_a_friendly_error
    error = refused do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      ship = sprite :ship, at: [40, 40]
      game_loop { ship.draw_with :hurt }
    end

    assert_match(/:hurt, which is not a list of colors/, error.message)
  end

  def test_a_sprite_whose_pictures_have_no_list_cannot_swap_colors
    error = refused do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP
      colors :hurt, HURT
      ship = sprite :ship, at: [40, 40]
      game_loop { ship.draw_with :hurt }
    end

    assert_match(/no `colors:` list/, error.message)
  end

  def test_a_list_shorter_than_the_sprites_own_is_a_friendly_error
    error = refused do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      colors :hurt, [:transparent, :yellow]
      ship = sprite :ship, at: [40, 40]
      game_loop { ship.draw_with :hurt }
    end

    assert_match(/has 2 colors/, error.message)
  end

  def test_showing_needs_a_list_and_a_list_needs_showing
    one = refused do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      colors :hurt, HURT
      ship = sprite :ship, at: [40, 40]
      game_loop { ship.draw_with :hurt, showing: 0 }
    end
    several = refused do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      colors :hurt, HURT
      ship = sprite :ship, at: [40, 40]
      game_loop { ship.draw_with [:hurt, :hurt] }
    end

    assert_match(/names one list/, one.message)
    assert_match(/nothing to pick/, several.message)
  end

  def test_a_sprite_on_a_bitmap_screen_cannot_draw_with_other_colors
    error = refused do
      screen :bitmap
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      colors :hurt, HURT
      ship = sprite :ship, at: [40, 40]
      game_loop { ship.draw_with :hurt }
    end

    assert_match(/screen :tiled/, error.message)
  end

  def test_a_pool_that_draws_nothing_cannot_draw_with_other_colors
    error = refused do
      screen :tiled
      colors :hurt, HURT
      ships = pool :ship, x: 0, y: 0, capacity: 2
      game_loop { ships.each { |ship| ship.draw_with :hurt } }
    end

    assert_match(/draw nothing/, error.message)
  end

  def test_a_list_of_colors_is_checked_where_it_is_declared
    own = refused { colors :own, HURT }
    twice = refused do
      colors :hurt, HURT
      colors :hurt, HURT
    end
    long = refused { colors :hurt, [:transparent, *Array.new(16, :red)] }

    assert_match(/cannot be named :own/, own.message)
    assert_match(/declared twice/, twice.message)
    assert_match(/2 to 16 colors/, long.message)
  end

  # Every different list takes one of the console's sixteen groups of sprite colours, and so
  # does the sprite's own. Seventeen is one too many.
  def test_more_lists_than_the_console_has_groups_for_is_a_friendly_error
    error = refused(GBA::LoweringError) do
      screen :tiled
      image :ship, width: 8, height: 8, data: SHIP, colors: OWN
      names = (1..16).map { |n| colors :"pulse#{n}", [:transparent, RubyGBA::Color.rgb(n, 0, 0), :white] }
      ship = sprite :ship, at: [40, 40]
      step = var :step, 0
      game_loop { ship.draw_with names, showing: step }
    end

    assert_match(/groups of colors/, error.message)
  end
end
