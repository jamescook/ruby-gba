# frozen_string_literal: true

require "test_helper"

# A SCREEN OF MANY STILL SPRITES, as Pokémon Pinball's field select draws its blinking border: 37
# pieces of 8×8 round a box, each its own sprite with three poses — three shades of the border —
# and some of them turned over, changing pose together every eight frames. Nothing moves. A Color
# with its frame to spare sleeps through most of each one, as the console's own screen does.
class TestGBCStillSprites < Minitest::Test
  PIECES = 37
  SHADES = %i[white gray black].freeze

  # The places round a box 10 pieces wide and 10 high — the most sprites a Color shows on one row
  # of the screen — and one in its middle: 37 of them.
  PLACES = ((0...10).map { |c| [c, 0] } + (1...9).flat_map { |r| [[0, r], [9, r]] } + (0...10).map { |c| [c, 9] } +
            [[5, 4]]).freeze

  # The border's game. +every_pass+ says whether each piece is given its pose on every pass, or
  # only on the pass the shade changes; the shade changes every +frames_a_shade+ passes.
  def self.border(every_pass:, frames_a_shade: 8)
    VBlank.game("STILL SPRITES", consoles: %i[gbc]) do
      screen :tiled
      # One list for all three shades, as a sprite draws every picture of its own from one: each
      # shade draws its edge in the next place of it.
      shades = TestGBCStillSprites::SHADES.each_with_index.map do |shade, s|
        image :"edge_#{shade}", width: 8, height: 8, colors: [:transparent, *TestGBCStillSprites::SHADES],
                                places: Array.new(64) { |i| (i % 8) < 2 || (i / 8) < 2 ? s + 1 : 0 }
        :"edge_#{shade}"
      end
      turned = shades.map { |name| mirror(name) }
      # The screen's fade, as lists the pieces are drawn with, the screen faded in already: given
      # once, before the loop.
      fades = (0...4).map do |step|
        colors :"fade#{step}", [:transparent, *(1..3).map { |c| rgb(31 - (step * 2), 31 - (c * 6), 31 - (step * c)) }]
        :"fade#{step}"
      end
      faded = var :faded, fades.length - 1
      pieces = TestGBCStillSprites::PLACES.each_with_index.map do |(c, r), n|
        own = n.odd? ? turned : shades
        piece = sprite :"piece#{n}", at: [16 + (c * 8), 16 + (r * 8)], facing: own.to_h { |p| [p, p] }
        piece.draw_with fades, showing: faded
        piece
      end
      shade = var :shade, 0
      tick = var :tick, 0
      game_loop do
        changed = tick == 0
        (tick >= frames_a_shade - 1).then { tick.set! 0 }.else { tick.add! 1 }
        changed.then { (shade == 2).then { shade.set! 0 }.else { shade.add! 1 } }
        give = lambda do
          pieces.each_with_index { |piece, n| piece.face(n.odd? ? turned : shades, showing: shade) }
        end
        every_pass ? give.call : changed.then { give.call }
      end
    end
  end

  def self.idle_share(every_pass:, frames_a_shade: 8)
    rom = border(every_pass: every_pass, frames_a_shade: frames_a_shade)
          .build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, frames: 120, settle: 20)
  end

  # Every piece changes its picture on every pass, and each pass still fits its frame, with room.
  def test_still_sprites_changing_their_poses_every_pass_fit_each_frame
    result = TestGBCStillSprites.idle_share(every_pass: true, frames_a_shade: 1)

    assert_equal result.frames, result.passes
    assert_operator result.idle_share, :>, 0.15
  end

  def test_still_sprites_given_their_poses_every_pass_leave_most_of_each_frame_asleep
    result = TestGBCStillSprites.idle_share(every_pass: true)

    assert_operator result.idle_share, :>, 0.5
  end

  def test_still_sprites_given_their_poses_now_and_then_leave_most_of_each_frame_asleep
    result = TestGBCStillSprites.idle_share(every_pass: false)

    assert_operator result.idle_share, :>, 0.5
  end

  def test_the_border_plays_as_the_interpreter_plays_it
    game_player.run(TestGBCStillSprites.border(every_pass: true).program(console: :gbc), frames: 30)
  end

  def test_the_border_given_its_poses_now_and_then_plays_as_the_interpreter_plays_it
    game_player.run(TestGBCStillSprites.border(every_pass: false).program(console: :gbc), frames: 30)
  end

  def test_the_border_changing_every_pass_plays_as_the_interpreter_plays_it
    game_player.run(TestGBCStillSprites.border(every_pass: true, frames_a_shade: 1).program(console: :gbc), frames: 30)
  end
end
