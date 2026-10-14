# frozen_string_literal: true

require "test_helper"
require "native_comparison"

# A game's art and tables are most of a desktop program, so each is kept at the width it needs:
# a table at the width the game declared it, a picture's pixel in the sixteen bits it is, a
# recording's sample in its byte. A big game's program was four times the size of its data for
# want of this. Here the C is the contract, so the tests read it; and a game reading every width
# both ways round still plays as the interpreter does.
class TestNativeDataWidths < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  def tables_game
    program_of do
      screen :bitmap
      bytes = table :bytes, [-128, -1, 0, 1, 127], width: :byte
      unsigned_bytes = table :unsigned_bytes, [0, 200, 255], width: :byte
      halves = table :halves, [-32_768, -2, 40_000 - 65_536, 32_767], width: :half
      unsigned_halves = table :unsigned_halves, [0, 40_000, 65_535], width: :half
      words = table :words, [-2_000_000_000, 7, 2_000_000_000], width: :word
      copied = list :copied, capacity: 3, width: :half
      sum = var :sum, 0
      i = var :i, 0
      game_loop do
        sum.set! bytes[i] + unsigned_bytes[i] + halves[i] + unsigned_halves[i] + words[i]
        copied.copy_from unsigned_halves, at: i, count: 2
        i.add! 1
      end
    end
  end

  def test_each_table_is_stored_at_the_width_the_game_declared
    c = Native.new.lower(tables_game)

    assert_match(/const int8_t \w*bytes\w*\[5\]/, c)
    assert_match(/const uint8_t \w*unsigned_bytes\w*\[3\]/, c)
    assert_match(/const int16_t \w*halves\w*\[4\]/, c)
    assert_match(/const uint16_t \w*unsigned_halves\w*\[3\]/, c)
    assert_match(/const int32_t \w*words\w*\[3\]/, c)
  end

  def test_a_game_reading_tables_of_every_width_plays_as_the_interpreter_does
    last = assert_native_matches_reference tables_game, frames: 5

    assert_operator last.variables[:i], :>, 2, "the game should have read several entries"
  end

  def art_and_sound_game
    program_of do
      screen :bitmap
      image(:dot, "#" => :red, "." => :transparent) { "#.\n" }
      sample :boom, pcm: [-128, -1, 0, 1, 127] * 4, rate: 8000
      game_loop { blit :dot, 10, 10 }
    end
  end

  def test_a_pixel_is_sixteen_bits_and_a_sample_one_byte
    c = Native.new.lower(art_and_sound_game)

    assert_match(/const int16_t rg_game_image_pixels\[/, c)
    assert_match(/const int8_t rg_game_recording_samples\[/, c)
  end
end
