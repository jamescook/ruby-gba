# frozen_string_literal: true

require "test_helper"
require "differential"

# A PICTURE MADE OF 8x8 PIECES, each where the game puts it: `image :frame, colors:, pieces:`, as a
# cartridge's own sprites are kept — a border of pieces off the 8-pixel grid, a figure whose arm
# piece overlaps its body. The earlier piece of two that overlap is in front, and every piece shows,
# on every console, however the pieces sit against the grid.
class TestImagePieces < Minitest::Test
  include Differential

  RED = VBlank::Graphics::Color.resolve(:red)
  BLUE = VBlank::Graphics::Color.resolve(:blue)

  # 64 places all +place+.
  def self.solid(place) = Array.new(64, place)

  private def built(pieces, at: [40, 40])
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :frame, colors: %i[transparent red blue], pieces: pieces
      sprite :frame, at: at
      game_loop {}
    end
    b.finalize_program
    b.program
  end

  private def shown(program) = game_player.run(program, frames: 3).screen

  def test_the_earlier_of_two_overlapping_pieces_is_in_front
    screen = shown(built([[0, 0, TestImagePieces.solid(1)], [4, 2, TestImagePieces.solid(2)]]))

    assert_equal RED, screen.pixel(45, 43), "where both pieces are, the first is in front"
    assert_equal BLUE, screen.pixel(50, 43), "the second shows where the first is not"
    assert_equal BLUE, screen.pixel(45, 49), "...below it too"
  end

  # Ten pieces in a row, each half a piece off the grid. Cut on the grid, the row would be eleven
  # pieces on the same lines, more than the Color shows on one.
  def test_a_row_of_pieces_off_the_grid_shows_every_piece
    pieces = Array.new(10) { |n| [4 + (8 * n), 0, TestImagePieces.solid(n.even? ? 1 : 2)] }
    screen = shown(built(pieces, at: [20, 40]))

    10.times do |n|
      assert_equal(n.even? ? RED : BLUE, screen.pixel(20 + 4 + (8 * n) + 3, 43), "piece #{n} shows")
    end
  end

  def test_the_advance_shows_the_same_pieces
    pieces = Array.new(10) { |n| [4 + (8 * n), n.odd? ? 3 : 0, TestImagePieces.solid(n.even? ? 1 : 2)] }
    assert_backends_agree(built(pieces, at: [20, 40]), frames: 3, name: "PIECES")
  end

  # Twenty-four sprites of two pieces, one under the other: forty-eight pieces, more than the forty
  # a Color shows. Told its pieces are 8x16, the Color shows each sprite as one, and every sprite
  # shows whole. Every other console draws the same picture.
  def test_every_sprite_of_stacked_pieces_shows_when_the_pieces_are_tall
    options = VBlank::Cartridge::Options.new(sprite_piece_size: { gbc: [8, 16] })
    b = Builder.new(options: options)
    places = Array.new(24) { |n| [8 + (24 * (n % 6)), 8 + (24 * (n / 6))] }
    b.instance_eval do
      screen :tiled
      image :stack, colors: %i[transparent red blue],
                    pieces: [[0, 0, TestImagePieces.solid(1)], [0, 8, TestImagePieces.solid(2)]]
      places.each { |at| sprite :stack, at: at }
      game_loop {}
    end
    b.finalize_program
    screen = shown(b.program)

    places.each_with_index do |(x, y), n|
      assert_equal RED, screen.pixel(x + 3, y + 3), "sprite #{n} shows its upper piece"
      assert_equal BLUE, screen.pixel(x + 3, y + 11), "...and its lower one"
    end
  end

  # Tall pieces turned upside down change halves, a piece with none under it shows alone, and a
  # picture drawn rather than made of pieces is cut 8x16 too.
  def test_tall_pieces_turn_stand_alone_and_cut_from_a_drawing
    options = VBlank::Cartridge::Options.new(sprite_piece_size: { gbc: [8, 16] })
    b = Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      image :stack, colors: %i[transparent red blue],
                    pieces: [[0, 0, TestImagePieces.solid(1)], [0, 8, TestImagePieces.solid(2)], [8, 4, TestImagePieces.solid(2)]]
      image :drawn, "R" => :red, "B" => :blue do
        ((["RRRRRRRRRRRR"] * 12) + (["BBBBBBBBBBBB"] * 12)).join("\n")
      end
      sprite :stack, at: [20, 20]
      sprite upside_down(:stack), at: [60, 20]
      sprite :drawn, at: [100, 20]
      game_loop {}
    end
    b.finalize_program
    screen = shown(b.program)

    assert_equal RED, screen.pixel(23, 23), "the upright stack's upper half"
    assert_equal BLUE, screen.pixel(23, 31), "...its lower half"
    assert_equal BLUE, screen.pixel(31, 27), "...and the piece beside, with nothing under it"
    assert_equal BLUE, screen.pixel(63, 23), "turned upside down, the lower half is on top"
    assert_equal RED, screen.pixel(63, 31), "...and the upper below"
    assert_equal BLUE, screen.pixel(71, 27), "...and the piece beside turned with it"
    assert_equal RED, screen.pixel(110, 30), "the drawing's upper half, cut into tall pieces"
    assert_equal BLUE, screen.pixel(110, 40), "...and its lower"
  end

  # A sprite whose poses are pictures of pieces reaching different sizes: two pieces in a row, three
  # reaching further down and across, and one alone. Each pose's pieces sit at their offsets from the
  # sprite's place, and a pose of fewer pieces shows none of a larger one's.
  private def changing_shape(from, to)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :medium, colors: %i[transparent red blue],
                     pieces: [[0, 0, TestImagePieces.solid(1)], [8, 0, TestImagePieces.solid(1)]]
      image :large, colors: %i[transparent red blue],
                    pieces: [[0, 0, TestImagePieces.solid(2)], [8, 0, TestImagePieces.solid(2)], [16, 8, TestImagePieces.solid(2)]]
      image :small, colors: %i[transparent red blue], pieces: [[0, 0, TestImagePieces.solid(1)]]
      shape = sprite :shape, at: [40, 40], facing: { medium: :medium, large: :large, small: :small }
      ticks = var :ticks, 0
      pick = var :pick, from
      game_loop do
        ticks.add! 1
        (ticks == 3).then { pick.set! to }
        shape.face %i[medium large small], showing: pick
      end
    end
    b.finalize_program
    b.program
  end

  private def shown_after_change(program) = game_player.run(program, frames: 8).screen

  def test_the_advance_shows_a_sprite_changing_shape_the_same
    assert_backends_agree(changing_shape(1, 2), frames: 8, name: "SHAPES")
  end

  def test_a_sprite_shrinking_to_a_smaller_pose_shows_only_its_pieces
    screen = shown_after_change(changing_shape(1, 2))
    empty = screen.pixel(150, 130)

    assert_equal RED, screen.pixel(43, 43), "the small pose's one piece"
    assert_equal empty, screen.pixel(51, 43), "the large pose's second piece is gone"
    assert_equal empty, screen.pixel(59, 51), "...and its third"
  end

  def test_a_sprite_growing_to_a_larger_pose_shows_all_its_pieces
    screen = shown_after_change(changing_shape(2, 1))

    assert_equal BLUE, screen.pixel(43, 43), "the large pose's first piece"
    assert_equal BLUE, screen.pixel(51, 43), "...its second"
    assert_equal BLUE, screen.pixel(59, 51), "...and its third, reaching past the others"
  end

  def test_a_sprite_shows_the_pose_of_two_pieces_it_starts_with
    screen = shown_after_change(changing_shape(0, 0))
    empty = screen.pixel(150, 130)

    assert_equal RED, screen.pixel(51, 43), "the medium pose's second piece"
    assert_equal empty, screen.pixel(59, 51), "nothing of the large pose"
  end

  # A block standing on the large pose's third piece, and nowhere the small pose reaches: the two
  # touch while the sprite is large, and not once it has shrunk.
  def test_a_sprite_touches_only_with_the_pose_it_shows
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :large, colors: %i[transparent red blue],
                    pieces: [[0, 0, TestImagePieces.solid(2)], [8, 0, TestImagePieces.solid(2)], [16, 8, TestImagePieces.solid(2)]]
      image :small, colors: %i[transparent red blue], pieces: [[0, 0, TestImagePieces.solid(1)]]
      image :block, colors: %i[transparent red blue], pieces: [[0, 0, TestImagePieces.solid(1)]]
      shape = sprite :shape, at: [40, 40], facing: { large: :large, small: :small }
      block = sprite :block, at: [58, 50]
      ticks = var :ticks, 0
      touched_large = var :touched_large, 0
      touched_small = var :touched_small, 0
      game_loop do
        ticks.add! 1
        (ticks == 2).then { shape.overlaps?(block).then { touched_large.set! 1 } }
        (ticks == 3).then { shape.face :small }
        (ticks == 5).then { shape.overlaps?(block).then { touched_small.set! 1 } }
      end
    end
    b.finalize_program
    run = game_player.run(b.program, frames: 8)

    assert_equal 1, run[:touched_large], "the large pose's third piece is under the block"
    assert_equal 0, run[:touched_small], "the small pose reaches nowhere near it"
  end

  def test_turning_a_sprite_with_poses_of_different_sizes_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :tiled
        image :wide, colors: %i[transparent red], pieces: [[0, 0, TestImagePieces.solid(1)], [8, 0, TestImagePieces.solid(1)]]
        image :narrow, colors: %i[transparent red], pieces: [[0, 0, TestImagePieces.solid(1)]]
        sprite(:spinner, at: [40, 40], facing: { wide: :wide, narrow: :narrow }).turn(5)
      end
    end

    assert_match(/poses are of different sizes \(16x8, 8x8\)/, error.message)
  end

  def test_a_piece_of_the_wrong_size_is_a_friendly_error
    error = assert_raises(ArgumentError) { built([[0, 0, Array.new(60, 1)]]) }

    assert_match(/give it 64 places/, error.message)
  end

  # Turned left to right, the row is still its pieces, each moved to the other side and turned.
  def test_a_mirrored_row_of_pieces_off_the_grid_shows_every_piece
    pieces = Array.new(10) { |n| [4 + (8 * n), 0, Array.new(64) { |i| (i % 8) < 2 ? 1 : 2 }] }
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image :frame, colors: %i[transparent red blue], pieces: pieces
      sprite :frame, at: [20, 40], facing: { turned: mirror(:frame) }
      game_loop {}
    end
    b.finalize_program
    screen = shown(b.program)

    # 88 wide: piece n now sits at 88 - 12 - 8n, its two red columns on its right.
    10.times do |n|
      left = 20 + 88 - 12 - (8 * n)
      assert_equal BLUE, screen.pixel(left, 43), "piece #{n} shows, its blue on the left"
      assert_equal RED, screen.pixel(left + 7, 43), "...and its red on the right"
    end
  end

  def test_a_piece_off_the_picture_is_a_friendly_error
    error = assert_raises(ArgumentError) { built([[-1, 0, TestImagePieces.solid(1)]]) }

    assert_match(/dx and dy are whole numbers from 0 to 247/, error.message)
  end

  def test_a_place_the_list_does_not_hold_is_a_friendly_error
    error = assert_raises(ArgumentError) { built([[0, 0, TestImagePieces.solid(1)], [8, 0, TestImagePieces.solid(5)]]) }

    assert_match(/its colors: list does not hold/, error.message)
  end

  def test_pieces_with_a_size_are_a_friendly_error
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        image :frame, width: 8, height: 8, colors: %i[transparent red], pieces: [[0, 0, TestImagePieces.solid(1)]]
      end
    end

    assert_match(/takes its pixels and its size from the pieces/, error.message)
  end
end
