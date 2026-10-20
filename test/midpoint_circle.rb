# frozen_string_literal: true

# THE CIRCLE THE CONSOLE'S GAMES DRAW THEIR WINDOWS WITH, written out the way The Minish Cap writes
# it (tmc: src/common.c — sub_0801E24C makes the half widths, and sub_0801E290 turns them into a span
# for rows y - n and y + n, n below the size). It is the answer key a light's rows are checked
# against, so it is written here from the game's code and never read from the framework's.
module MidpointCircle
  WIDTH = 240
  HEIGHT = 160

  # Each row's lit [left, right) for a circle of +size+ centred on (+x+, +y+), the right edge one
  # past the last lit column; nil for a row the circle does not reach.
  def game_circle_spans(x, y, size)
    widths = Array.new(size + 1, 0)
    across = 0
    down = size
    turn = 3 - (2 * size)
    while across <= down
      widths[across] = down
      widths[down] = across
      if turn.negative?
        turn += 6 + (across * 4)
      else
        turn += 10 + ((across - down) * 4)
        down -= 1
      end
      across += 1
    end
    spans = Array.new(HEIGHT)
    size.times do |n|
      left = [x - widths[n], 0].max
      right = x + widths[n] > 239 ? 240 : x + widths[n]
      [y - n, y + n].each { |row| spans[row] = [left, right] if (0...HEIGHT).cover?(row) }
    end
    spans
  end

  # ...as a game shows them that hands the console each row's span in the gap after the row
  # above: each row the span worked out for the row above it, and the top row its own.
  def game_circle_spans_a_row_late(x, y, size)
    spans = game_circle_spans(x, y, size)
    Array.new(HEIGHT) { |row| spans[[row - 1, 0].max] }
  end

  # Each row's lit columns in a picture of a white room under a light of darkness 100, as
  # [left, right), or nil for a row with none.
  def lit_spans(screen, white = RubyGBA::Graphics::Color.resolve(:white))
    Array.new(HEIGHT) do |row|
      lit = (0...WIDTH).select { |column| screen.pixel(column, row) == white }
      lit.empty? ? nil : [lit.first, lit.last + 1]
    end
  end

  # The rows two lists of spans disagree on, said row by row: minitest's own diff of two long
  # lists cannot run inside a Ractor.
  def assert_same_spans(expected, got, what)
    wrong = (0...HEIGHT).reject { |row| expected[row] == got[row] }
    assert wrong.empty?, "#{what}: #{wrong.size} rows differ, the first #{wrong.first(3).map do |row|
      "row #{row} is #{got[row].inspect}, the game's #{expected[row].inspect}"
    end.join('; ')}"
  end
end
