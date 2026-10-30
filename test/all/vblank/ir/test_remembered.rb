# frozen_string_literal: true

require "test_helper"

# WHAT IS WORKED OUT ABOUT A PICTURE IS WORKED OUT ONCE A CORE, by the picture's contents.
class TestRemembered < Minitest::Test
  Remembered = VBlank::IR::Remembered
  Image = VBlank::IR::Assets::Image

  private def picture(pixels)
    Image.new(width: 2, height: 1, transparent: nil, pixels: pixels.pack("v*"), colors: nil, places: nil)
  end

  # Each test asks a question of its own, so what another test kept cannot answer it.
  private def question = :"#{name}_question"

  def test_a_picture_made_again_with_the_same_pixels_is_answered_without_the_work
    worked = 0
    first = Remembered.fetch(question, picture([1, 2])) { worked += 1 and [1, 2] }
    again = Remembered.fetch(question, picture([1, 2])) { worked += 1 and [9, 9] }
    assert_equal 1, worked
    assert_equal first, again
  end

  def test_a_picture_with_other_pixels_is_worked_out_for_itself
    Remembered.fetch(question, picture([1, 2])) { :first }
    assert_equal :second, Remembered.fetch(question, picture([2, 1])) { :second }
  end

  # An answer is handed to every later build, so nothing may change it on the way.
  def test_an_answer_cannot_be_changed_by_whoever_is_handed_it
    pieces = Remembered.fetch(question, picture([3, 4])) { [[0, 0, 8, 8]] }
    assert_raises(FrozenError) { pieces << [8, 0, 8, 8] }
    assert_raises(FrozenError) { pieces.first[0] = 1 }
  end

  # Each core keeps its own, so a core that has worked nothing out does the work itself.
  def test_another_core_works_its_answer_out_for_itself
    asked = question
    Remembered.fetch(asked, picture([5, 6])) { :here }
    there = Ractor.new(asked) do |q|
      VBlank::IR::Remembered.fetch(q, VBlank::IR::Assets::Image.new(width: 2, height: 1, transparent: nil,
                                                                      pixels: [5, 6].pack("v*"), colors: nil,
                                                                      places: nil)) { :there }
    end.value
    assert_equal :there, there
  end

  # A full store starts again with the next new answer, and what was kept before is worked
  # out again the same.
  def test_a_full_store_starts_again
    Ractor.new do
      remembered = VBlank::IR::Remembered
      remembered::ENTRIES.times { |n| remembered.fetch(:filling, n) { n } }
      remembered.fetch(:filling, :one_more) { :one_more }
      kept_after = remembered.size
      worked = false
      remembered.fetch(:filling, 0) { worked = true and 0 }
      [worked, kept_after]
    end.value => [worked, kept_after]
    assert_equal 1, kept_after
    assert worked, "an answer from before the store filled up is worked out again"
  end
end
