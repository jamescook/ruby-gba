# frozen_string_literal: true

require "test_helper"
require "stringio"

# THE GAP BETWEEN FRAMES BELONGS TO THE PICTURE. It is the only time the sprite table can be
# written without the screen catching it half done, and mixing a heavy song can take longer than
# the whole gap. When the sound was built there, the game's sprite writes landed after the next
# picture had started, so its top rows showed last frame's sprites. A console test only: the
# interpreter has no gap and no clock.
class TestMixerLeavesTheGap < Minitest::Test
  # A screen of 228 lines, 68 of them the gap: a frame busier than this share is busier than
  # the gap alone could hold, so the mixing cannot have fitted inside it.
  GAP_SHARE = 68.0 / 228

  # ...and the mix has to be done two thirds of a frame after it starts.
  MIX_ROOM = 160.0 / 228

  VOICES = 10

  # Looping voices at a high rate: more mixing than the gap holds, and well inside the two
  # thirds of a frame the mix has once it waits for the first line.
  def self.heavy_game
    RubyGBA.build("GAP", out: StringIO.new, err: StringIO.new, profile: false) do
      screen :tiled
      image(:top, "#" => :white) { "########\n" * 8 }
      image(:low, "#" => :white) { "########\n" * 8 }
      top = sprite :top, at: [0, 0]
      low = sprite :low, at: [0, 140]
      pcm = Array.new(4096) { |i| ((i * 7) % 200) - 100 }
      clips = Array.new(VOICES) { |n| sample :"clip#{n}", pcm: pcm, rate: 32_768 }
      x = var :x, 0
      started = var :started, 0
      game_loop do
        (started == 0).then do
          clips.each { |clip| clip.play(loop: true) }
          started.set! 1
        end
        x.add! 2
        (x > 200).then { x.set! 0 }
        top.move_to x, 0
        low.move_to x, 140
      end
    end
  end

  def white_column(verifier, row)
    (0...240).find { |col| verifier.white?(col, row) }
  end

  # Two sprites moved together, one in the top rows and one near the bottom, stand at the same
  # place in every picture.
  def test_sprites_at_the_top_move_on_the_frame_the_rest_do
    rom = self.class.heavy_game
    busy = 1 - RubyGBA::Diagnostics::Profiler.run(rom, frames: 30, picture: false).idle_share
    assert_operator busy, :>, GAP_SHARE, "the song must be heavier than the gap, or this tests nothing"
    assert_operator busy, :<, MIX_ROOM, "the song must fit the room the mix has"

    v = RubyGBA::Diagnostics::Verifier.new(rom, frames: 20)
    places = Array.new(6) do
      v.step
      [white_column(v, 3), white_column(v, 143)]
    end
    refute_includes places.flatten, nil, "both sprites must be on screen: #{places.inspect}"
    places.each { |top, low| assert_equal low, top, "the top sprite is a frame behind: #{places.inspect}" }
    assert_predicate v, :sound?, "the song still plays"
  end
end
