# frozen_string_literal: true

require "test_helper"
require "differential"

# THE TESTS OF ruby_gba/builder/test_picture_places.rb THAT ONLY THE GAME BOY ADVANCE CAN PLAY, kept apart so that the
# Game Boy Color's run never loads them (TestSuites::ADVANCE_DIR); the rest are in that file.
#
# A PICTURE WHOSE PIXELS ARE PLACES IN ITS OWN LIST OF COLOURS.
#
# Art made anywhere else on this console arrives as numbers picking out of a table, and every
# picture the framework keeps holds a whole colour per pixel instead. Those are the same
# picture right up until the table holds one colour twice — and a palette lifted out of a real
# cartridge nearly always does, two blacks or two whites — because a colour then no longer says
# which place it came from. That matters because a sprite drawn with another list swaps colours
# BY PLACE: the two places are one colour in the art and two different colours in the list it is
# drawn with, so the picture has to remember which of them each pixel meant.
class TestPicturePlacesOnTheAdvance < Minitest::Test
  include Differential

  # Red twice, at places 1 and 3, with green between them.
  OWN = %i[transparent red green red].freeze
  HURT = %i[transparent yellow white blue].freeze

  # An 8x8 picture: left half place 1, right half place 3. Both halves are red, so nothing
  # about its pixels tells the two apart.
  PLACES = Array.new(64) { |i| (i % 8) < 4 ? 1 : 3 }.freeze

  private def program(&game)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, colors: OWN, places: PLACES
      colors :hurt, HURT
      ship = sprite :ship, at: [40, 40]
      game_loop { instance_exec(ship, &game) }
    end
    builder.finalize_program
    builder.program
  end

  # Two pictures whose pixels are identical and whose places are not. The console stores a
  # pose once when it has seen the same picture before, so it has to judge that on the
  # places too — otherwise the second frame draws the first one's colours.
  private def two_frames_program
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :near, width: 8, height: 8, colors: OWN, places: Array.new(64) { 1 }
      image :far, width: 8, height: 8, colors: OWN, places: Array.new(64) { 3 }
      colors :hurt, HURT
      ship = sprite :ship, at: [40, 40], frames: %i[near far], rate: 1
      game_loop { ship.draw_with :hurt }
    end
    builder.finalize_program
    builder.program
  end

  # A pose whose pixels are an earlier pose's pixels backwards is stored once and drawn
  # reversed — which is only the same picture if its PLACES are that pose's places backwards
  # too. Here they are not: both poses draw red beside green, out of different places of the
  # list, so drawing the second as the first reversed would show the wrong colour.
  private def two_ways_round_program
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :one, width: 8, height: 8, colors: OWN, places: Array.new(64) { |i| (i % 8) < 4 ? 1 : 2 }
      image :two, width: 8, height: 8, colors: OWN, places: Array.new(64) { |i| (i % 8) < 4 ? 2 : 3 }
      colors :hurt, HURT
      ship = sprite :ship, at: [40, 40], frames: %i[one two], rate: 1
      game_loop { ship.draw_with :hurt }
    end
    builder.finalize_program
    builder.program
  end

  # THE SAME PICTURE THE OTHER WAY ROUND has to turn its places round with it, and nothing
  # about the pixels says so: this art is red both halves, so reversing the pixels changes
  # nothing at all and only the places tell the two sides apart.
  private def mirrored_program
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
    builder.finalize_program
    builder.program
  end

  # A LIST SHAPED THE WAY A REAL CARTRIDGE'S IS, which differs from the lists above in two
  # ways that both bear on the same trap. Its entries are the console's own colour values
  # rather than names, so its see-through entry is written as a number like the rest; and
  # the colour it repeats is BLACK, which is the value that see-through entry holds too.
  # Three of its six entries are therefore identical, and a picture that matched a pixel by
  # colour would hand every black pixel the see-through place and draw a character full of
  # holes. Half the palettes on a real cartridge repeat a colour, most often black.
  CART_LIST = [0x0000, 0x7FFF, 0x001F, 0x0000, 0x03E0, 0x0000].freeze
  CART_SWAP = [0x0000, 0x7FFF, 0x001F, 0x7C00, 0x03E0, 0x03FF].freeze

  # Black from place 3, black from place 5, then nothing.
  CART_PLACES = Array.new(64) { |i| [3, 3, 3, 5, 5, 5, 0, 0][i % 8] }.freeze

  private def cartridge_program
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :link, width: 8, height: 8, colors: CART_LIST, places: CART_PLACES, transparent: true
      colors :hurt, CART_SWAP
      hero = sprite :link, at: [40, 40]
      game_loop { hero.draw_with :hurt }
    end
    builder.finalize_program
    builder.program
  end

  def test_one_colour_at_three_places_including_the_see_through_one_stays_apart
    i = game_player.run(cartridge_program, frames: 2)

    assert_equal 0x7C00, i.screen.pixel(41, 41), "black from place 3"
    assert_equal 0x03FF, i.screen.pixel(44, 41), "black from place 5"
    assert_equal 0x0000, i.screen.pixel(47, 41), "place 0 draws nothing"
  end

  def test_the_console_keeps_those_three_apart_too
    oracle, console, = backend_pictures(cartridge_program, frames: 2)

    assert_equal 0x7C00, console[(41 * 240) + 41], "black from place 3"
    assert_equal 0x03FF, console[(41 * 240) + 44], "black from place 5"
    assert_equal 0x0000, console[(41 * 240) + 47], "place 0 draws nothing"
    assert_empty mismatched_pixels(oracle, console)
  end

  # --- art given as colours, where the two places cannot be told apart ---

  # The same picture drawn the ordinary way: every pixel a colour, so the two reds are one
  # pixel value and nothing says which place either came from.
  COLORS = Array.new(64) { :red }.freeze

  private def refused(&block)
    assert_raises(ArgumentError) do
      RubyGBA.build("PLACES", code: "BPLC", maker: "01", out: StringIO.new, err: StringIO.new, &block)
    end
  end

  # A cartridge's palette keeps a real colour in its see-through slot, and the art often draws
  # that same colour from a later place. A pixel of that colour is drawn from the later place,
  # so the list goes in exactly as the cartridge had it.
  RAW_FIRST = [0x001F, 0x7FFF, 0x001F].freeze

  private def raw_first_program
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :ship, width: 8, height: 8, data: COLORS, colors: RAW_FIRST
      colors :hurt, [0x0000, 0x7FFF, 0x7C00]
      plain = sprite :ship, at: [40, 40]
      hurt = sprite :hurt_ship, at: [80, 40], facing: { right: :ship }
      game_loop { hurt.draw_with :hurt; plain.show }
    end
    builder.finalize_program
    builder.program
  end

  # --- friendly errors on the places themselves ---

end
