# frozen_string_literal: true

require "test_helper"
require "differential"

# A CANVAS: a picture the game draws into with words while it runs — a pixel, a rectangle, a
# picture stamped on, a letter, a line of text, a number — in colour names.
#
# It is built from what a game could write itself, so what is worth testing is what it draws,
# on both backends, and the rules a newcomer would trip over: a letter that crosses from one
# tile into the next, and a meter that empties without leaving its old length behind.
class TestCanvas < Minitest::Test
  include Differential

  WHITE = RubyGBA::Graphics::Color.resolve(:white)
  RED = RubyGBA::Graphics::Color.resolve(:red)

  # A 64x16 canvas shown at the top-left of a tiled screen. +body+ runs every pass with the
  # canvas and a frame counter.
  def game(&body)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :ink, %i[transparent white red blue]
      image(:dot, "." => :transparent, "#" => :red) { "##\n#." }
      board = canvas :board, width: 64, height: 16, colors: :ink
      background :front, tiles: :board, map: board.cells
      frame = var :frame, 0
      game_loop do
        frame.add! 1
        instance_exec(board, frame, &body)
      end
    end
    b.finalize_program
    b.program
  end

  def screen(prog, frames) = Reference.new.run(prog, frames: frames).screen

  def test_a_pixel_shows_on_the_frame_after_it_is_drawn
    prog = game { |board, frame| (frame == 2).then { board.pixel 3, 2, :white } }

    assert_equal 0, screen(prog, 2).pixel(3, 2)
    assert_equal WHITE, screen(prog, 3).pixel(3, 2)
  end

  # "W" is five pixels wide; drawn at 6 it runs from the first tile into the second.
  def test_a_letter_that_crosses_a_tile_edge_lands_in_both
    prog = game { |board, _frame| board.clear; board.draw_letter "W", 6, 0, :white }
    picture = screen(prog, 3)
    lit = (0...8).flat_map { |y| (6..10).select { |x| picture.pixel(x, y) == WHITE } }

    assert_includes lit, 6, "the letter starts in the first tile"
    assert_operator lit.max, :>=, 8, "and carries on into the second"
  end

  # A meter that empties and a dot that moves: each frame clears and draws again, so nothing
  # of the frame before is left.
  def test_clearing_leaves_no_trail_of_a_meter_or_a_moving_dot
    prog = game do |board, frame|
      board.clear
      board.fill_rect 0, 0, 20 - frame, 4, :red
      board.pixel frame, 10, :white
    end
    picture = screen(prog, 10)

    assert_equal 0, picture.pixel(15, 1), "the meter has emptied past here"
    assert_equal RED, picture.pixel(5, 1), "and is still full here"
    assert_equal 0, picture.pixel(3, 10), "the dot is not where it was"
  end

  # Every word at once, with positions and a letter the game works out, compared over the
  # whole screen between the console and the interpreter.
  def every_word
    game do |board, frame|
      board.clear :blue
      board.fill_rect 1, 1, 5, 3, :red
      board.pixel frame, 12, :white
      board.blit :dot, 10, 2
      board.draw_text "Hi", 20, 0, :white
      board.draw_number frame, 40, 0, :white, digits: 3
      pen = board.draw_letter 65 + (frame & 3), 20, 8, :red
      board.draw_letter "!", pen + 20, 8, :white
    end
  end

  def test_the_console_draws_every_word_as_the_interpreter_does
    oracle, console = backend_pictures(every_word, frames: 6)

    assert_equal [WHITE, RED, RubyGBA::Graphics::Color.resolve(:blue)].sort, (oracle.uniq - [0]).sort,
                 "every colour drawn, so the comparison means something"
    assert_empty mismatched_pixels(oracle, console)
  end

  def test_a_canvas_can_be_a_sprites_picture
    b = Builder.new
    b.instance_eval do
      screen :tiled
      tag = canvas :tag, width: 16, height: 8, colors: %i[transparent white], as: :sprite
      sprite :tag, at: [30, 30]
      game_loop { tag.pixel 9, 1, :white }
    end
    b.finalize_program

    assert_equal WHITE, screen(b.program, 3).pixel(39, 31)
  end

  # A letter hands back where it ended, and a game that has no use for that must still build:
  # the whole build, guardrails and all, not only the tree.
  def test_drawing_words_whose_answer_nobody_reads_build
    rom = RubyGBA.build("CANVAS", out: nil, err: nil) do
      screen :tiled
      board = canvas :board, width: 64, height: 16, colors: %i[transparent white]
      background :front, tiles: :board, map: board.cells
      game_loop do
        board.draw_letter "A", 0, 0, :white
        board.draw_text "OK", 10, 0, :white
      end
    end

    assert_operator rom.size, :>, 0
  end

  def refusal(screen_kind: :tiled, &block)
    assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen screen_kind
        instance_eval(&block)
        game_loop {}
      end
      b.finalize_program
    end.message
  end

  def test_mistakes_are_friendly_errors
    assert_match(/multiple of 8/, refusal { canvas :c, width: 20, height: 8, colors: %i[transparent white] })
    assert_match(/not one of its colours/,
                 refusal { canvas(:c, width: 8, height: 8, colors: %i[transparent white]).pixel(1, 1, :red) })
    assert_match(/outside it/, refusal { canvas(:c, width: 8, height: 8, colors: %i[transparent white]).pixel(9, 1, :white) })
    assert_match(/use `pixel` or `blit`/,
                 refusal(screen_kind: :bitmap) { canvas :c, width: 8, height: 8, colors: %i[transparent white] })
    assert_match(/:tiles .* or :sprite/,
                 refusal { canvas :c, width: 8, height: 8, colors: %i[transparent white], as: :wall })
  end
end
