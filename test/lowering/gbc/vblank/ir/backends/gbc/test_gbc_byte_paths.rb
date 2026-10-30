# frozen_string_literal: true

require "test_helper"

# THE QUICK WAYS A COLOR CARTRIDGE TAKES WITH A BYTE written in the program — a comparison with
# one, a number held between two of them, a number times one (Lowering#emit_compare_with_byte,
# #value_of_clamped, #emit_product_by_byte) — give what the long ways give for every number,
# below nought and past a byte included. Every answer is checked against the interpreter's on
# every pass.
class TestGBCBytePaths < Minitest::Test
  STEP = 37

  # Each number a quick way can get wrong: either side of every end the game below writes, the
  # last byte and the first number past it, a number whose low byte is small but whose upper bytes
  # are not, and the two ends of a number, which a product wraps past.
  EDGES = [-1, 0, 2, 3, 4, 5, 6, 7, 8, 199, 200, 201, 249, 250, 251, 254, 255, 256, 257, 259,
           -256, -255, 65_536, 16_843_009, 0x7FFF_FFFF, -0x8000_0000].freeze

  ANSWERS = %i[below at_most above at_least under_nought at_most_last_byte
               held held_to_byte held_to_one times_seven times_byte times_three].freeze

  # The answers a number gives, set into the game's variables.
  private def answer(answers, n)
    { below: n < 5, at_most: n <= 200, above: n > 255, at_least: n >= 250, under_nought: n < 0,
      at_most_last_byte: n <= 255 }.each do |name, holds|
      holds.then { answers[name].set! 1 }.else { answers[name].set! 0 }
    end
    answers[:held].set! n.clamp(3, 250)
    answers[:held_to_byte].set! n.clamp(0, 255)
    answers[:held_to_one].set! n.clamp(7, 7)
    answers[:times_seven].set! n * 7
    answers[:times_byte].set! n * 255
    answers[:times_three].set! n * 3
  end

  # A number walking from far below nought to past a byte.
  private def walking_number
    test = self
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      # Four strides of 9001 from here land on -185, and steps of 37 then walk past 255.
      n = var :n, -36_189
      answers = ANSWERS.to_h { |name| [name, var(name, 0)] }
      steps = table :steps, [3, 1, 4, 1, 5]
      picked = var :picked, 0
      game_loop do
        (n.abs < 400).then { n.add! TestGBCBytePaths::STEP }.else { n.add! 9_001 }
        test.send(:answer, answers, n)
        picked.set! steps[n]
      end
    end
    b.finalize_program
    b.program
  end

  # Each of EDGES in turn, one a pass.
  private def edge_numbers
    test = self
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      edges = table :edges, TestGBCBytePaths::EDGES, width: :word
      at = var :at, 0
      n = var :n, 0
      answers = ANSWERS.to_h { |name| [name, var(name, 0)] }
      game_loop do
        n.set! edges[at]
        test.send(:answer, answers, n)
        at.add! 1
      end
    end
    b.finalize_program
    b.program
  end

  def test_every_answer_is_the_interpreters_for_a_walking_number
    game_player.run(walking_number, frames: 60)
  end

  def test_every_answer_is_the_interpreters_at_each_edge
    game_player.run(edge_numbers, frames: EDGES.size + 2)
  end
end
