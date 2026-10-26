# frozen_string_literal: true

require "test_helper"

# `list :name, capacity: N, full_of: value` — a list that starts holding N items, every one
# the value given, where a list without it starts empty. A game that wants room it can index
# into from the first frame (a box it letters text into, a row of flags) says so here rather
# than pushing N items one at a time as it starts.
class TestListFullOf < Minitest::Test
  private def interpret(frames: 1, &block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    game_player.run(builder.program, frames: frames)
  end

  def test_a_list_full_of_a_value_holds_its_capacity_of_that_value_from_the_start
    result = interpret do
      marks = list :marks, capacity: 5, full_of: 7
      held = var :held, 0
      first = var :first, 0
      last = var :last, 0
      game_loop do
        held.set! marks.length
        first.set! marks[0]
        last.set! marks[4]
      end
    end

    assert_equal [5, 7, 7], [result[:held], result[:first], result[:last]]
  end

  # A fraction says the list holds fractions, as `holds: 0.0` does, and the items read back
  # as that fraction.
  def test_a_list_full_of_a_fraction_holds_fractions
    result = interpret do
      speeds = list :speeds, capacity: 3, full_of: 1.5
      doubled = var :doubled, 0.0
      game_loop { doubled.set! speeds[2] * 2 }
    end

    assert_in_delta 3.0, result[:doubled].to_f / (1 << VBlank::DSL::Fraction::DEFAULT_BITS), 0.001
  end

  def test_a_fraction_in_a_list_of_whole_numbers_is_refused
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { list :marks, capacity: 3, holds: 0, full_of: 1.5 } }

    assert_match(/holds whole numbers/, error.message)
  end

  def test_something_other_than_a_number_is_refused
    error = assert_raises(ArgumentError) { Builder.new.instance_eval { list :marks, capacity: 3, full_of: :zero } }

    assert_match(/full_of: 0/, error.message)
  end

  # Every width, a value below nothing, and an odd count of bytes so the fill has ends that
  # are not whole words; the item after the list is never written. A list longer than a Game
  # Boy Color holds, read on the Advance's cartridge, is in test/advance/.
  READINGS = %i[bytes_held byte_first byte_last half_last word_first word_last after_first ring_first ring_last].freeze
  WIDTHS = proc do
    bytes = list :bytes, capacity: 99, width: :byte, full_of: -1, fast: false
    halves = list :halves, capacity: 3, width: :half, full_of: 300
    words = list :words, capacity: 2, full_of: -70_000
    after = list :after, capacity: 1
    after.push 9
    # A list the game shifts is a ring on the console, its slots rounded up past the capacity.
    ring = list :ring, capacity: 3, full_of: 4
    ring.shift
    ring.push 6
    readings = READINGS.to_h { |name| [name, var(name, 0)] }
    game_loop do
      readings[:bytes_held].set! bytes.length
      readings[:byte_first].set! bytes[0]
      readings[:byte_last].set! bytes[98]
      readings[:half_last].set! halves[2]
      readings[:word_first].set! words[0]
      readings[:word_last].set! words[1]
      readings[:after_first].set! after[0]
      readings[:ring_first].set! ring[0]
      readings[:ring_last].set! ring[2]
    end
  end

  def test_every_width_starts_full
    builder = Builder.new
    builder.instance_eval(&WIDTHS)
    builder.finalize_program
    run = game_player.run(builder.program, frames: 2)

    assert_equal [99, -1, -1, 300, -70_000, -70_000, 9, 4, 6], READINGS.map { |name| run[name] }
  end
end
