# frozen_string_literal: true

require "test_helper"

# A CI log shows a line only once it ends, and minitest's dots are one line for the whole run,
# so a run there says nothing until it finishes. The progress lines break it every hundred tests.
class TestProgressLines < Minitest::Test
  def test_says_how_many_tests_have_played_every_hundred
    io = StringIO.new
    lines = VBlank::Testing::ProgressLines.new(io, total: 250)
    250.times { lines.record(nil) }

    assert_equal ["100 of 250 tests played", "200 of 250 tests played"], io.string.lines.map(&:strip).reject(&:empty?)
  end

  def test_each_line_stands_on_its_own_between_the_dots
    io = StringIO.new
    lines = VBlank::Testing::ProgressLines.new(io, total: 100)
    io.print "." * 100
    100.times { lines.record(nil) }

    assert_equal "#{'.' * 100}\n100 of 100 tests played\n", io.string
  end
end
