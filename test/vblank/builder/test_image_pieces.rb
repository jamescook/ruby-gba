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
