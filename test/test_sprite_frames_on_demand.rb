# frozen_string_literal: true

require "test_helper"
require "stringio"
require "differential"

# A CHARACTER COSTS THE SPRITE MEMORY OF THE FRAME IT IS SHOWING, not of every frame it could
# show, when that is what it takes to fit.
#
# The console draws sprites out of 32K of picture memory. A character with a full set of
# animations can fill that on its own, and then nobody else fits beside it, even though it
# only ever shows one frame at a time.
class TestSpriteFramesOnDemand < Minitest::Test
  include Differential

  # Fifteen colours, so every picture is stored the small way (half a byte a pixel).
  INKS = (1..15).map { |i| RubyGBA::Color.rgb(i * 2, 31 - (i * 2), 10) }.freeze

  # A 32x32 picture that fills its whole square and differs from every other one made here:
  # a slanted stripe pattern, with the picture's number written along the top row in two inks.
  # No two are the same, and none is another one reversed.
  def frame_art(number)
    (0...32).flat_map do |y|
      (0...32).map do |x|
        next INKS[(number >> x) & 1] if y.zero?

        INKS[((x * 5) + (y * 3)) % 15]
      end
    end
  end

  # Link's measurement from picori: 63 frames of 32x32, which is 32,256 of the 32,768 bytes, and
  # an enemy of two frames beside him.
  def crowded_screen
    frames = (0...63).map { |n| :"hero_#{n}" }
    b = Builder.new
    art = method(:frame_art)
    b.instance_eval do
      screen :tiled
      frames.each_with_index { |name, n| image name, width: 32, height: 32, data: art.call(n) }
      image :enemy_0, width: 32, height: 32, data: art.call(100)
      image :enemy_1, width: 32, height: 32, data: art.call(101)
      sprite :hero, at: [40, 40], frames: frames, rate: 1
      sprite :enemy, at: [120, 60], frames: %i[enemy_0 enemy_1], rate: 2
      game_loop {}
    end
    b.emit_pending_functions
    b.program
  end

  # The bead's own shape: three facings of 21 frames each, the fourth facing the third one
  # reversed, and an enemy beside him. The character turns left partway through, so a frame
  # drawn from another one's pictures, reversed, is among the ones compared.
  def turning_screen
    facings = %i[down up right].to_h { |dir| [dir, (0...21).map { |n| :"hero_#{dir}_#{n}" }] }
    b = Builder.new
    art = method(:frame_art)
    b.instance_eval do
      screen :tiled
      facings.values.flatten.each_with_index { |name, n| image name, width: 32, height: 32, data: art.call(n) }
      image :enemy_0, width: 32, height: 32, data: art.call(100)
      image :enemy_1, width: 32, height: 32, data: art.call(101)
      hero = sprite :hero, at: [40, 40], rate: 1,
                           facing: facings.merge(left: mirror(facings[:right]))
      sprite :enemy, at: [120, 60], frames: %i[enemy_0 enemy_1], rate: 2
      tick = var :tick, 0
      game_loop do
        tick.add 1
        (tick == 2).then { hero.face :right }
        (tick == 4).then { hero.face :left }
      end
    end
    b.emit_pending_functions
    b.program
  end

  def test_a_character_facing_the_other_way_shows_its_frames_reversed
    assert_backends_agree(turning_screen, frames: 6, name: "TURN")
  end

  # A 48x48 character is bigger than any one picture the console draws, so each frame is cut
  # into pieces — and a frame that draws less is cut into fewer, smaller ones. Here the drawn
  # part grows from a corner frame by frame, so no two frames are cut alike.
  def growing_art(number)
    reach = 16 + (number % 33)
    (0...48).flat_map do |y|
      (0...48).map do |x|
        next :transparent if x >= reach || y >= reach

        INKS[((x * 5) + (y * 3) + number) % 15]
      end
    end
  end

  def big_character_screen
    frames = (0...33).map { |n| :"giant_#{n}" }
    b = Builder.new
    art = method(:growing_art)
    enemy = method(:frame_art)
    b.instance_eval do
      screen :tiled
      frames.each_with_index do |name, n|
        image name, width: 48, height: 48, data: art.call(n), transparent: true
      end
      image :enemy_0, width: 32, height: 32, data: enemy.call(100)
      image :enemy_1, width: 32, height: 32, data: enemy.call(101)
      sprite :giant, at: [40, 40], frames: frames, rate: 1
      sprite :enemy, at: [140, 60], frames: %i[enemy_0 enemy_1], rate: 2
      game_loop {}
    end
    b.emit_pending_functions
    b.program
  end

  def test_a_character_cut_into_pieces_shows_each_frame_whole
    [3, 12, 30].each do |frames|
      assert_backends_agree(big_character_screen, frames: frames, name: "GIANT")
    end
  end

  # A scene's pictures go into the same memory another scene's used. So a character that keeps
  # one frame at a time, in a scene the game leaves and comes back to, finds its frame written
  # over by the other scene's pictures — and has to copy it in again even though the frame it is
  # showing never changed. It animates slowly here so that nothing else would copy it.
  def two_scene_screen
    frames = (0...63).map { |n| :"hero_#{n}" }
    b = Builder.new
    art = method(:frame_art)
    b.instance_eval do
      screen :tiled
      frames.each_with_index { |name, n| image name, width: 32, height: 32, data: art.call(n) }
      image :enemy_0, width: 32, height: 32, data: art.call(100)
      image :enemy_1, width: 32, height: 32, data: art.call(101)
      image :banner, width: 32, height: 32, data: art.call(200)
      var :state, 0
      tick = var :tick, 0
      scene :playing do
        sprite :hero, at: [40, 40], frames: frames, rate: 60
        sprite :enemy, at: [120, 60], frames: %i[enemy_0 enemy_1], rate: 60
      end
      scene :paused do
        sprite :banner, at: [40, 40]
      end
      game_loop do
        tick.add 1
        (tick == 3).then { set :state, 1 }
        (tick == 5).then { set :state, 0 }
        case_var(:state) do
          when_val 0, :playing
          when_val 1, :paused
        end
      end
    end
    b.emit_pending_functions
    b.program
  end

  def test_a_character_back_in_its_scene_shows_its_frame_again
    assert_backends_agree(two_scene_screen, frames: 8, name: "SCENES")
  end

  # Sixty-five different still pictures, one sprite each. None animates, so none has frames to
  # keep one at a time, and together they are more than sprite memory holds.
  def test_still_pictures_that_do_not_fit_are_a_friendly_error
    b = Builder.new
    art = method(:frame_art)
    b.instance_eval do
      screen :tiled
      65.times do |n|
        image :"statue_#{n}", width: 32, height: 32, data: art.call(n)
        sprite :"statue_#{n}", at: [n, n]
      end
      game_loop {}
    end
    b.emit_pending_functions
    err = assert_raises(GBA::LoweringError) { GBA.new.lower(b.program) }
    assert_match(/statue/, err.message)
    assert_match(/one frame at a time/, err.message)
  end

  def test_a_character_with_a_full_set_of_animations_leaves_room_for_another
    rom = ROM.assemble(GBA.new.lower(crowded_screen), title: "CROWD", code: "BCRW", maker: "01")
    assert_kind_of ROM, rom
  end

  # Both are animating, at different speeds, so frames several steps into the cycle are the
  # ones compared rather than the first one.
  def test_the_character_shows_the_frame_it_is_on_as_it_animates
    assert_backends_agree(crowded_screen, frames: 7, name: "CROWD")
  end
end
