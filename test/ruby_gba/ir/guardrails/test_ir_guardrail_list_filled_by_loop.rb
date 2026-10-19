# frozen_string_literal: true

require "test_helper"

# A list a game fills to its capacity with one value, a push at a time, in its setup —
# `repeat(64) { name.push 0 }` — does what `full_of: 0` on its declaration does, at many times
# the work. The build says so, naming the list and the line, and builds the game all the same.
class TestIRGuardrailListFilledByLoop < Minitest::Test
  private def warnings(&game)
    err = StringIO.new
    RubyGBA.build("FILLED", out: StringIO.new, err: err, profile: false, &game)
    err.string
  end

  def test_a_list_pushed_full_of_one_value_in_a_loop_is_pointed_at_full_of
    said = warnings do
      name = list :name, capacity: 64, width: :byte
      repeat(64) { name.push 0 }
      game_loop { name[0] = 1 }
    end

    assert_match(/:name/, said)
    assert_match(/full_of: 0/, said)
    assert_match(/#{File.basename(__FILE__)}:\d+/, said)
  end

  # A loop that stops itself once the list is full fills it the same way.
  def test_a_loop_that_stops_when_the_list_is_full_is_pointed_at_it_too
    said = warnings do
      kept = list :kept, capacity: 8
      repeat(8, stop_when: kept.length >= 8) { kept.push(-1) }
      game_loop { kept[0] = 1 }
    end

    assert_match(/:kept/, said)
    assert_match(/full_of:/, said)
  end

  def test_a_loop_that_fills_part_of_a_list_or_pushes_different_values_is_left_alone
    said = warnings do
      part = list :part, capacity: 8
      repeat(4) { part.push 0 }
      counting = list :counting, capacity: 8
      repeat(8) { |i| counting.push i }
      game_loop { part[0] = counting[1] }
    end

    refute_match(/full_of/, said)
  end

  # Filled again while the game plays, after it emptied the list, is not what a declaration
  # does, so it is not pointed at one.
  def test_a_list_filled_again_while_the_game_plays_is_left_alone
    said = warnings do
      marks = list :marks, capacity: 8
      game_loop do
        pressed(:a).then do
          repeat(marks.length) { marks.pop }
          repeat(8) { marks.push 0 }
        end
      end
    end

    refute_match(/full_of/, said)
  end
end
