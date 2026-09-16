# frozen_string_literal: true

require "test_helper"
require "stringio"

# A capacity, a rate, a size, how many digits: a dozen verbs will not accept an argument
# that is not a whole number above zero, and they all ask {RubyGBA::Whole} the same
# question. What they must NOT share is the answer they give back.
#
# Each of these errors teaches something only that verb knows — a timer points at `every`
# for slower timing, a grid says a cell must be even so the fast fill is legal, a sprite
# says a rate is how many game frames a picture is shown for. Sharing the question is
# housekeeping; sharing the sentence would cost the reader the one thing the guardrail is
# for, and nothing else in the suite would notice.
class TestWholeNumberGuardrails < Minitest::Test
  def build(&block)
    RubyGBA.build("WHOLE", code: "BWHL", maker: "01", err: StringIO.new, out: StringIO.new, &block)
  end

  # Each verb, and the words only that verb's message has any business saying.
  def refusals
    {
      "timer" => [/every/, -> { build { screen :bitmap; timer :beat, per_second: 0 } }],
      "grid cols" => [/grid :board/, -> { build { screen :bitmap; grid :board, cols: 0, rows: 4, cell: 8, over: :black } }],
      "grid cell" => [/even/, -> { build { screen :bitmap; grid :board, cols: 4, rows: 4, cell: 7, over: :black } }],
      "pool" => [/pool :bits/, -> { build { screen :bitmap; pool :bits, x: 0, capacity: 0 } }],
      "draw_number" => [/draw_number/, -> { build { screen :bitmap; draw_number :n, 0, 0, :white, digits: 0 } }],
      "sprite rate" => [/picture is shown/, lambda {
        build do
          screen :bitmap
          image(:a, "#" => :white) { "#\n" }
          image(:b, "#" => :red) { "#\n" }
          sprite :thing, at: [0, 0], frames: %i[a b], rate: 0
        end
      }],
      "shake intensity" => [/intensity/, -> { build { screen :bitmap; game_loop { shake_screen intensity: 0 } } }],
      "list capacity" => [/list/, -> { RubyGBA::IR::Build.list_new(:xs, 0) }]
    }
  end

  def test_every_verb_refuses_a_number_that_is_not_whole_and_above_zero
    refusals.each do |verb, (_, attempt)|
      assert_raises(ArgumentError, "#{verb} accepted a count of zero") { attempt.call }
    end
  end

  # ...and each says its own thing while doing it.
  def test_each_refusal_keeps_the_words_only_it_can_say
    refusals.each do |verb, (distinctive, attempt)|
      message = assert_raises(ArgumentError) { attempt.call }.message

      assert_match distinctive, message, "#{verb} lost the part of its message only it can give"
    end
  end

  # The sharpest form of the same guard: no two of these verbs may answer with the same
  # sentence. A shared helper that raised on the caller's behalf would collapse them, and
  # this is what would notice.
  def test_no_two_verbs_give_the_same_sentence
    messages = refusals.transform_values { |(_, attempt)| assert_raises(ArgumentError) { attempt.call }.message }
    duplicated = messages.values.tally.select { |_, count| count > 1 }.keys

    assert_empty duplicated, "these verbs answer with the same words, so one of them is not teaching"
  end
end
