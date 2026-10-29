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

  # The border as a game that copies a cartridge's screen writes it: its pieces declared in the scene they show
  # in and hidden until the screen has faded in, each piece's three shades drawn from one list,
  # which the fade steps through 33 lists given only on the passes the fade moves; then shown, the
  # shade picked from a table of the blink's steps and the column from a table by the field chosen.
  def self.faded_border(frames_a_shade: 8)
    VBlank.game("FADED BORDER", consoles: %i[gbc]) do
      screen :tiled
      showing = var :showing, 0
      scene :border do
        colors :edge, [:transparent, :white, :white, :white]
        steps = (0...33).map do |step|
          level = [step, 33 - step].min
          colors :"edge_step#{step}", [:transparent, *(1..3).map { |c| rgb(31 - level, 31 - (c * level / 3), 31 - (level / 2)) }]
          :"edge_step#{step}"
        end
        shades = TestGBCStillSprites::SHADES.each_with_index.map do |shade, s|
          image :"edge_#{shade}", width: 8, height: 8, colors: :edge,
                                  places: Array.new(64) { |i| (i % 8) < 2 || (i / 8) < 2 ? s + 1 : 0 }
          :"edge_#{shade}"
        end
        turned = shades.map { |name| mirror(name) }
        poses = %i[pose0 pose1 pose2]
        pieces = TestGBCStillSprites::PLACES.each_with_index.map do |(c, r), n|
          own = n.odd? ? turned : shades
          sprite :"piece#{n}", at: [16 + (c * 8), 16 + (r * 8)], facing: poses.zip(own).to_h, shown: false
        end
        blink = table :blink, [0, 1, 0, 2]
        columns = table :columns, [16, 64]
        field = var :field, 0
        passes = var :passes, 0
        fade = var :fade, 0
        step = var :step, 0
        tick = var :tick, 0
        fading = passes < 17
        fading.then { fade.set! passes }
        (fading | (passes == 17)).then { pieces.each { |piece| piece.draw_with steps, showing: fade } }
        (passes >= 18).then do
          (tick == 0).then do
            pieces.each_with_index do |piece, n|
              piece.show
              piece.face poses, showing: blink[step]
              piece.x.set! columns[field] + ((n % 10) * 8)
            end
            step.set!((step + 1) & 3)
          end
          (tick >= frames_a_shade - 1).then { tick.set! 0 }.else { tick.add! 1 }
        end
        passes.add! 1
      end
      game_loop do
        case_var(:showing) { when_val 0, :border }
      end
    end
  end

  # The same border as ONE sprite whose three poses are each a picture of the 37 pieces
  # (`image ..., pieces:`), as a cartridge keeps the border: one sprite placed in one call.
  def self.pieced_border
    VBlank.game("PIECED BORDER", consoles: %i[gbc]) do
      screen :tiled
      poses = TestGBCStillSprites::SHADES.each_index.map do |s|
        pieces = TestGBCStillSprites::PLACES.each_with_index.map do |(c, r), n|
          edge = Array.new(64) { |i| (i % 8) < 2 || (i / 8) < 2 ? s + 1 : 0 }
          [c * 8, r * 8, n.odd? ? edge.each_slice(8).map(&:reverse).flatten : edge]
        end
        image :"border#{s}", colors: [:transparent, *TestGBCStillSprites::SHADES], pieces: pieces
        [:"pose#{s}", :"border#{s}"]
      end.to_h
      border = sprite :border, at: [16, 16], facing: poses
      shade = var :shade, 0
      game_loop do
        (shade == 2).then { shade.set! 0 }.else { shade.add! 1 }
        border.face poses.keys, showing: shade
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

  # Shown, every piece changing its shade on every pass, each pass still fits its frame: the
  # scene's sprites are passed over as unchanged like any others, and a change of the pose alone
  # rewrites each piece where it is.
  def test_a_scene_s_faded_border_changing_every_pass_fits_each_frame
    rom = TestGBCStillSprites.faded_border(frames_a_shade: 1)
                             .build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: 60, settle: 40)

    assert_equal result.frames, result.passes
    assert_operator result.idle_share, :>, 0.05
  end

  # One sprite of 37 pieces changing its picture on every pass leaves most of each frame asleep.
  def test_a_border_of_one_sprite_in_pieces_changing_every_pass_sleeps_most_of_each_frame
    rom = TestGBCStillSprites.pieced_border.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: 60, settle: 20)

    assert_equal result.frames, result.passes
    assert_operator result.idle_share, :>, 0.5
  end

  def test_a_border_of_one_sprite_in_pieces_plays_as_the_interpreter_plays_it
    game_player.run(TestGBCStillSprites.pieced_border.program(console: :gbc), frames: 12)
  end

  def test_a_scene_s_faded_border_plays_as_the_interpreter_plays_it
    game_player.run(TestGBCStillSprites.faded_border(frames_a_shade: 3).program(console: :gbc), frames: 40)
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
