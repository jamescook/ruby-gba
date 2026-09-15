# frozen_string_literal: true

require "test_helper"
require "differential"

# A PICTURE WHOSE PIXELS ARE PLACES IN ITS OWN LIST OF COLOURS.
#
# Art made anywhere else on this console arrives as numbers picking out of a table, and every
# picture the framework keeps holds a whole colour per pixel instead. Those are the same
# picture right up until the table holds one colour twice — and a palette lifted out of a real
# cartridge nearly always does, two blacks or two whites — because a colour then no longer says
# which place it came from. That matters because a sprite drawn with another list swaps colours
# BY PLACE: the two places are one colour in the art and two different colours in the list it is
# drawn with, so the picture has to remember which of them each pixel meant.
class TestPicturePlaces < Minitest::Test
  include Differential

  # Red twice, at places 1 and 3, with green between them.
  OWN = %i[transparent red green red].freeze
  HURT = %i[transparent yellow white blue].freeze

  # An 8x8 picture: left half place 1, right half place 3. Both halves are red, so nothing
  # about its pixels tells the two apart.
  PLACES = Array.new(64) { |i| (i % 8) < 4 ? 1 : 3 }.freeze

  def program(&game)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, colors: OWN, places: PLACES
      colors :hurt, HURT
      ship = sprite :ship, at: [40, 40]
      game_loop { instance_exec(ship, &game) }
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_picture_given_places_draws_the_colors_they_name
    i = Reference.new.run(program { |ship| ship.draw_with :own }, frames: 2)

    assert_equal Color.resolve(:red), i.screen.pixel(41, 41), "place 1"
    assert_equal Color.resolve(:red), i.screen.pixel(45, 41), "place 3, the same colour"
  end

  def test_each_place_shows_its_own_color_from_the_list_drawn_with
    i = Reference.new.run(program { |ship| ship.draw_with :hurt }, frames: 2)

    assert_equal Color.resolve(:yellow), i.screen.pixel(41, 41), "place 1"
    assert_equal Color.resolve(:blue), i.screen.pixel(45, 41), "place 3"
  end

  # Agreement alone would not catch this: both backends read a repeated colour at the first
  # place it sits, so both were wrong together. The console's own pixels are named here.
  def test_the_console_tells_the_two_places_apart_too
    oracle, console, = backend_pictures(program { |ship| ship.draw_with :hurt }, frames: 2)

    assert_equal Color.resolve(:yellow), console[(41 * 240) + 41], "place 1"
    assert_equal Color.resolve(:blue), console[(41 * 240) + 45], "place 3"
    assert_empty mismatched_pixels(oracle, console)
  end

  # Two pictures whose pixels are identical and whose places are not. The console stores a
  # pose once when it has seen the same picture before, so it has to judge that on the
  # places too — otherwise the second frame draws the first one's colours.
  def two_frames_program
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :near, width: 8, height: 8, colors: OWN, places: Array.new(64) { 1 }
      image :far, width: 8, height: 8, colors: OWN, places: Array.new(64) { 3 }
      colors :hurt, HURT
      ship = sprite :ship, at: [40, 40], frames: %i[near far], rate: 1
      game_loop { ship.draw_with :hurt }
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_two_pictures_of_one_colour_at_different_places_are_kept_apart
    shown = (2..3).map { |frames| Reference.new.run(two_frames_program, frames: frames).screen.pixel(41, 41) }

    assert_equal %i[blue yellow].map { |name| Color.resolve(name) }.sort, shown.sort,
                 "one frame is drawn at place 1 and the other at place 3"
  end

  def test_the_console_keeps_those_two_apart_too
    (2..3).each { |frames| assert_backends_agree(two_frames_program, frames: frames) }
  end

  # A pose whose pixels are an earlier pose's pixels backwards is stored once and drawn
  # reversed — which is only the same picture if its PLACES are that pose's places backwards
  # too. Here they are not: both poses draw red beside green, out of different places of the
  # list, so drawing the second as the first reversed would show the wrong colour.
  def two_ways_round_program
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :one, width: 8, height: 8, colors: OWN, places: Array.new(64) { |i| (i % 8) < 4 ? 1 : 2 }
      image :two, width: 8, height: 8, colors: OWN, places: Array.new(64) { |i| (i % 8) < 4 ? 2 : 3 }
      colors :hurt, HURT
      ship = sprite :ship, at: [40, 40], frames: %i[one two], rate: 1
      game_loop { ship.draw_with :hurt }
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_pose_that_reads_as_an_earlier_one_backwards_keeps_its_own_places
    (2..3).each { |frames| assert_backends_agree(two_ways_round_program, frames: frames) }
  end

  # THE SAME PICTURE THE OTHER WAY ROUND has to turn its places round with it, and nothing
  # about the pixels says so: this art is red both halves, so reversing the pixels changes
  # nothing at all and only the places tell the two sides apart.
  def mirrored_program
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :lean, width: 8, height: 8, colors: OWN, places: PLACES
      colors :hurt, HURT
      facing = sprite :lean, at: [40, 40], facing: { right: :lean, left: mirror(:lean) }
      turning = sprite :turn, at: [100, 40], facing: { right: :lean }
      game_loop do
        facing.face :left
        turning.face_angle 90
        [facing, turning].each { |thing| thing.draw_with :hurt }
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_mirrored_pose_turns_its_places_round_with_it
    i = Reference.new.run(mirrored_program, frames: 3)

    assert_equal Color.resolve(:blue), i.screen.pixel(41, 41), "place 3, now on the left"
    assert_equal Color.resolve(:yellow), i.screen.pixel(45, 41), "and place 1 on the right"
  end

  def test_the_console_carries_places_through_every_way_it_draws_a_sprite
    oracle, console, = backend_pictures(mirrored_program, frames: 3)

    assert_equal Color.resolve(:blue), console[(41 * 240) + 41], "place 3, now on the left"
    assert_equal Color.resolve(:yellow), console[(41 * 240) + 45], "and place 1 on the right"
    assert_empty mismatched_pixels(oracle, console)
  end

  # A PICTURE THE CONSOLE STORES THE BIG WAY HAS NO PLACES TO KEEP. A background that can
  # turn and resize reads a whole byte a pixel out of the one shared table, where a colour
  # is a single entry however many places the author's list gave it — so a place number
  # names an unrelated entry there and the colour has to be looked up instead.
  def test_a_picture_stored_the_big_way_is_still_drawn_in_its_own_colors
    map = Array.new(32) { Array.new(32, " ") }
    map[10][25] = "#"
    builder = Builder.new
    builder.instance_eval do
      screen :rotozoom
      image :spot, width: 8, height: 8, colors: OWN, places: Array.new(64) { 3 }
      tiles :t, "#" => :spot
      background :board, tiles: :t, map: map.map(&:join)
      game_loop {}
    end
    builder.emit_pending_functions
    oracle, console, = backend_pictures(builder.program, frames: 2)

    assert_equal Color.resolve(:red), console[(80 * 240) + 200], "place 3 of the list is red"
    assert_empty mismatched_pixels(oracle, console)
  end

  # --- art given as colours, where the two places cannot be told apart ---

  # The same picture drawn the ordinary way: every pixel a colour, so the two reds are one
  # pixel value and nothing says which place either came from.
  COLORS = Array.new(64) { :red }.freeze

  def refused(&block)
    assert_raises(ArgumentError) do
      RubyGBA.build("PLACES", code: "BPLC", maker: "01", out: StringIO.new, err: StringIO.new, &block)
    end
  end

  def test_a_repeated_color_the_other_list_splits_is_a_friendly_error
    error = refused do
      screen :tiled
      image :ship, width: 8, height: 8, data: COLORS, colors: OWN
      colors :hurt, HURT
      ship = sprite :ship, at: [40, 40]
      game_loop { ship.draw_with :hurt }
    end

    assert_match(/:red at place 1 and place 3/, error.message)
    assert_match(/places: \[\.\.\.\]/, error.message, "and says how to say which place each pixel meant")
  end

  # Nothing is wrong while the other list agrees about the two places, so nothing is said.
  def test_a_repeated_color_the_other_list_keeps_together_is_left_alone
    rom = RubyGBA.build("PLACES", out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image :ship, width: 8, height: 8, data: COLORS, colors: OWN
      colors :hurt, %i[transparent yellow white yellow]
      ship = sprite :ship, at: [40, 40]
      game_loop { ship.draw_with :hurt }
    end

    assert_operator rom.size, :>, 0
  end

  # The repeated colour is only a problem where the art draws it.
  def test_a_repeated_color_the_art_never_draws_is_left_alone
    rom = RubyGBA.build("PLACES", out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image :ship, width: 8, height: 8, data: Array.new(64) { :green }, colors: OWN
      colors :hurt, HURT
      ship = sprite :ship, at: [40, 40]
      game_loop { ship.draw_with :hurt }
    end

    assert_operator rom.size, :>, 0
  end

  # --- friendly errors on the places themselves ---

  def test_places_without_a_list_of_colors_is_a_friendly_error
    error = refused do
      screen :tiled
      image :ship, width: 8, height: 8, places: PLACES
    end

    assert_match(/given places: and no colors:/, error.message)
  end

  def test_places_and_pixels_together_is_a_friendly_error
    error = refused do
      screen :tiled
      image :ship, width: 8, height: 8, data: COLORS, places: PLACES, colors: OWN
    end

    assert_match(/both data: and places:/, error.message)
  end

  def test_the_wrong_number_of_places_is_a_friendly_error
    error = refused do
      screen :tiled
      image :ship, width: 8, height: 8, places: [1, 2, 3], colors: OWN
    end

    assert_match(/needs 64 places. Got 3/, error.message)
  end

  # The console leaves a pixel alone at place 0 and paints it everywhere else, so a list
  # that is see-through further along has no colour to paint there.
  def test_drawing_at_a_place_the_list_is_see_through_at_is_a_friendly_error
    error = refused do
      screen :tiled
      image :ship, width: 8, height: 8, places: Array.new(64) { 2 },
                   colors: %i[transparent red transparent]
    end

    assert_match(/see-through at that place/, error.message)
    assert_match(/Only place 0 means see-through/, error.message)
  end

  def test_places_on_art_drawn_in_characters_is_a_friendly_error
    error = refused do
      screen :tiled
      image :ship, "#" => :red, colors: OWN, places: PLACES do
        (["########"] * 8).join("\n")
      end
    end

    assert_match(/art drawn in characters/, error.message)
  end

  def test_a_place_the_list_does_not_hold_is_a_friendly_error
    error = refused do
      screen :tiled
      image :ship, width: 8, height: 8, places: Array.new(64) { 9 }, colors: OWN
    end

    assert_match(/draws at place 9/, error.message)
    assert_match(/0 to 3/, error.message)
  end
end
