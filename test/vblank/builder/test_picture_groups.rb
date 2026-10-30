# frozen_string_literal: true

require "test_helper"

# PICTURES GROUPED BY ROOM. A scene made of many rooms shows only one room's things at a time
# (two while the screen slides from one to the next), and the console keeps the pictures it
# draws sprites from in a memory small enough that a whole game's things do not fit in it at
# once. So a game says which of its pictures belong to which room, and which rooms are up; the
# cartridge then keeps only those. Here: that the game plays as it would with every picture
# loaded, and that the mistakes which would show garbage on the console stop the game in plain
# words instead.
class TestPictureGroups < Minitest::Test
  # A red square and a blue one, each a room's thing, and a white one every room shows.
  private def boxes
    lambda do |builder|
      { red_box: :red, blue_box: :blue, white_box: :white }.each do |name, color|
        builder.image(name, "#" => color) { Array.new(8) { "#" * 8 }.join("\n") }
      end
    end
  end

  # A boat showing the red box or the blue one by +look+, and the white box in no group. The
  # block says which groups are up, before the game loop and on each pass: the sprites are first
  # drawn in the gap before the loop's first pass, and their pictures have to be up for that.
  # +options+ are how it is built (a size of sprite piece, say).
  private def harbor(look:, up_together: nil, options: VBlank::Cartridge::Options.new, &up)
    b = Builder.new(options: options)
    paint = boxes
    b.instance_eval do
      screen :tiled
      paint.call(self)
      seen = var :look, look
      rooms = picture_groups :rooms, { 0 => %i[red_box], 1 => %i[blue_box], 2 => %i[red_box] }, **{ up_together: up_together }.compact
      boat = sprite :boat, facing: { red: :red_box, blue: :blue_box }, at: [40, 40]
      sprite :flag, facing: { white: :white_box }, at: [80, 40]
      instance_exec(rooms, &up)
      boat.face %i[red blue], showing: seen
      game_loop do
        instance_exec(rooms, &up)
        boat.face %i[red blue], showing: seen
      end
    end
    b.finalize_program
    b.program
  end

  private def red = Color.resolve(:red)

  def test_a_game_with_groups_draws_what_it_would_without_them
    screen = game_player.run(harbor(look: 0) { |rooms| rooms.show 0 }, frames: 3).screen

    assert_equal red, screen.pixel(42, 42), "the boat, in the red box of room 0"
    assert_equal Color.resolve(:white), screen.pixel(82, 42), "a picture in no group is always up"
  end

  # On the console the boat would draw from tiles holding some other room's pictures.
  def test_a_sprite_showing_a_picture_whose_group_is_not_up_stops_the_game
    error = assert_raises(Reference::ProgramError) do
      game_player.run(harbor(look: 1) { |rooms| rooms.show 0 }, frames: 3)
    end

    assert_match(/:boat/, error.message)
    assert_match(/:blue_box/, error.message)
    assert_match(/group 1 of :rooms/, error.message)
  end

  # Rooms 0 and 1 can be up together, and 0 and 2 are shown together.
  def test_two_groups_up_that_were_never_said_to_be_up_together_stop_the_game
    error = assert_raises(Reference::ProgramError) do
      game_player.run(harbor(look: 0, up_together: [[0, 1]]) { |rooms| rooms.show 0, 2 }, frames: 3)
    end

    assert_match(/groups 0 and 2 of :rooms/, error.message)
    assert_match(/up_together/, error.message)
  end

  # On a Color whose sprite pieces are 8x16, a grouped picture's tiles are pairs, and each still
  # comes up with its group.
  def test_groups_of_tall_pieces_draw_what_they_would_without_them
    options = VBlank::Cartridge::Options.new(sprite_piece_size: { gbc: [8, 16] })
    program = harbor(look: 1, up_together: [[0, 1]], options: options) { |rooms| rooms.show 0, 1 }
    screen = game_player.run(program, frames: 3).screen

    assert_equal Color.resolve(:blue), screen.pixel(42, 42), "the boat, in the blue box of room 1"
    assert_equal Color.resolve(:white), screen.pixel(82, 42), "a picture in no group is always up"
  end

  def test_groups_said_to_be_up_together_can_be
    program = harbor(look: 1, up_together: [[0, 1]]) { |rooms| rooms.show 0, 1 }

    assert_equal Color.resolve(:blue), game_player.run(program, frames: 3).screen.pixel(42, 42)
  end

  # A room with no things has no group: nothing of it is up, and that is no mistake.
  def test_a_number_naming_no_group_is_an_empty_group
    program = harbor(look: 0, up_together: [[0, 1]]) { |rooms| rooms.show 0, 9 }

    assert_equal red, game_player.run(program, frames: 3).screen.pixel(42, 42)
  end

  # The console draws a mirrored picture from its own picture's tiles, so it is up exactly when
  # that picture is: in group 0 with the red box, and not up while only group 1 is.
  def test_a_mirrored_picture_is_in_its_own_pictures_groups
    b = Builder.new
    paint = boxes
    b.instance_eval do
      screen :tiled
      paint.call(self)
      rooms = picture_groups :rooms, { 0 => %i[red_box], 1 => %i[blue_box] }
      sprite :boat, facing: { back: mirror(:red_box) }, at: [40, 40]
      rooms.show 1
      game_loop { rooms.show 1 }
    end
    b.finalize_program

    error = assert_raises(Reference::ProgramError) { game_player.run(b.program, frames: 3) }
    assert_match(/group 0 of :rooms/, error.message)
  end

  # A pool's empty slots draw nothing, so their picture need not be up; the first fish spawned
  # draws, and then it must be.
  private def fishing(spawn_on:)
    b = Builder.new
    paint = boxes
    b.instance_eval do
      screen :tiled
      paint.call(self)
      passes = var :passes, 0
      rooms = picture_groups :rooms, { 0 => %i[red_box], 1 => %i[blue_box] }
      fish = pool :fish, x: 40, y: 40, capacity: 4, image: :blue_box
      rooms.show 0
      game_loop do
        rooms.show 0
        passes.add! 1
        (passes == spawn_on).then { fish.spawn(x: 40, y: 40) }
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_pools_empty_slots_need_no_group_up
    assert_equal 3, game_player.run(fishing(spawn_on: 99), frames: 3)[:passes]
  end

  def test_a_pools_live_slot_needs_its_group_up
    error = assert_raises(Reference::ProgramError) { game_player.run(fishing(spawn_on: 1), frames: 3) }

    assert_match(/:fish/, error.message)
    assert_match(/group 1 of :rooms/, error.message)
  end

  # --- what the build refuses ---

  private def refused(screen_mode: :tiled, &block)
    paint = boxes
    error = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen screen_mode
        paint.call(self)
        instance_exec(&block)
      end
      b.finalize_program
    end
    error.message
  end

  # A bitmap screen paints its sprites into the picture: there is no sprite memory to save.
  def test_groups_on_a_bitmap_screen_are_refused
    message = refused(screen_mode: :bitmap) { picture_groups :rooms, { 0 => %i[red_box] } }

    assert_match(/screen :bitmap/, message)
    assert_match(/screen :tiled/, message)
  end

  def test_a_group_naming_a_picture_that_is_not_there_is_refused
    message = refused { picture_groups :rooms, { 0 => %i[red_box green_box] } }

    assert_match(/:green_box/, message)
    assert_match(/not a picture/, message)
  end

  def test_up_together_naming_a_group_that_is_not_there_is_refused
    message = refused { picture_groups :rooms, { 0 => %i[red_box] }, up_together: [[0, 5]] }

    assert_match(/group 5/, message)
  end

  # --- scenes ---

  private def harbor_scene(&up)
    b = Builder.new
    paint = boxes
    b.instance_eval do
      screen :tiled
      paint.call(self)
      var :state, 0
      passes = var :passes, 0
      scene(:sea) do
        rooms = picture_groups :rooms, { 0 => %i[red_box] }
        sprite :boat, facing: { red: :red_box }, at: [40, 40]
        instance_exec(rooms, passes, &up)
      end
      game_loop do
        passes.add! 1
        case_var(:state) { when_val 0, :sea }
      end
    end
    b.finalize_program
    b.program
  end

  # The scene says which room is up on its every pass, and its sprites are first drawn after
  # its first one.
  def test_a_scene_that_says_its_group_is_up_draws_it
    program = harbor_scene { |rooms, _passes| rooms.show 0 }

    assert_equal red, game_player.run(program, frames: 3).screen.pixel(42, 42)
  end

  # A scene taking over for the first time has none of its groups up until it says so: the boat,
  # drawn before the scene says which room is up, has nothing to draw from.
  def test_a_scene_taking_over_has_no_group_up_until_it_says
    program = harbor_scene { |rooms, passes| (passes > 2).then { rooms.show 0 } }

    error = assert_raises(Reference::ProgramError) { game_player.run(program, frames: 3) }
    assert_match(/No group of :rooms is up/, error.message)
  end

  # The sea loads first, hands the screen to the port for two passes, and is given it back. On
  # the pass it takes over on none of its own code runs, so it cannot say which room is up before
  # its boat is drawn again, showing what it showed as the sea was left.
  private def harbor_left_and_given_back
    b = Builder.new
    paint = boxes
    b.instance_eval do
      screen :tiled
      paint.call(self)
      state = var :state, 0
      passes = var :passes, 0
      scene(:sea, loads_first: true) do
        rooms = picture_groups :rooms, { 0 => %i[red_box], 1 => %i[blue_box] }
        sprite :boat, facing: { red: :red_box }, at: [40, 40]
        rooms.show 0
      end
      scene(:port) { sprite :flag, facing: { white: :white_box }, at: [80, 40] }
      game_loop do
        passes.add! 1
        (passes == 3).then { state.set! 1 }
        (passes == 5).then { state.set! 0 }
        case_var(:state) { when_val 0, :sea; when_val 1, :port }
      end
    end
    b.finalize_program
    b.program
  end

  # A scene given the screen back has its groups up as it left them, as it has its sprites.
  def test_a_scene_given_the_screen_back_has_its_groups_up_as_it_left_them
    screen = game_player.run(harbor_left_and_given_back, frames: 8).screen

    assert_equal red, screen.pixel(42, 42)
  end
end
