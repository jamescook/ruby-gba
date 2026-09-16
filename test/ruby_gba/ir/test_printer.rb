# frozen_string_literal: true

require "test_helper"

# The printer every report writes its lines through, and the COLOURED one in particular.
#
# That one is why this file exists. A report captured to a StringIO — which is what every
# other test in this suite does — gets the plain printer, and the plain printer ignores
# what a line MEANS entirely. So the whole colour path ran only on a real terminal, where
# nothing checks it, and a report could die there while every test stayed green. It did:
# the one severity the library actually passes had no colour, and asking for a colour that
# was not there raised.
#
# The lines that carry a severity are the picture verdicts, and each is printed only when
# the news is bad — so the failure landed exactly where a report is most needed.
class TestPrinter < Minitest::Test
  Printer = RubyGBA::IR::Printer
  Profiler = RubyGBA::Diagnostics::Profiler

  RED = "\e[31m"

  # A coloured printer and the text it wrote.
  def colored
    io = StringIO.new
    yield Printer.for(io, color: true)
    io.string
  end

  # --- which printer a report gets ---

  def test_a_report_captured_or_piped_is_plain
    assert_instance_of RubyGBA::IR::PlainPrinter, Printer.for(StringIO.new)
  end

  # --- the picture verdicts, which are the only lines that carry a severity ---

  def torn = Profiler::Tear.new(looked: 6, torn: 4, worst: 97)
  def held_together = Profiler::Tear.new(looked: 6, torn: 0, worst: 0)
  def flickering = RubyGBA::Diagnostics::Flicker::Reading.new(pixels: 1842, first: [40, 12])
  def all_arrived = RubyGBA::Diagnostics::Flicker::Reading.new(pixels: 0, first: nil)
  def dropped_sounds = RubyGBA::Diagnostics::SoundDrops::Reading.new(dropped: 7, music_held: 9, voices: 16)

  def test_a_torn_picture_says_so_in_colour
    line = colored { |printer| Profiler.tearing_line(torn, printer) }

    assert_includes line, "the picture tore on 4 of the 6 frames"
    assert line.start_with?(RED), "a fault a person has to act on is the alarm colour"
  end

  def test_lost_drawing_says_so_in_colour
    line = colored { |printer| Profiler.flicker_line(flickering, printer) }

    assert_includes line, "1842 pixels flicker"
    assert line.start_with?(RED)
  end

  def test_sounds_that_did_not_play_say_so_in_colour
    line = colored { |printer| Profiler.sound_drop_lines(dropped_sounds, printer) }

    assert_includes line, "7 sounds did not play"
    assert line.start_with?(RED)
  end

  # RED IS AN ALARM, NOT A LABEL. A game whose picture came out right shows none of it —
  # which is what keeps it meaning "act on this" rather than becoming something a reader
  # learns to scroll past.
  def test_a_picture_that_came_out_right_shows_no_colour_at_all
    good_news = colored do |printer|
      Profiler.tearing_line(held_together, printer)
      Profiler.flicker_line(all_arrived, printer)
    end

    refute_includes good_news, "\e[", "nothing on a healthy report is coloured"
    assert_includes good_news, "held together"
    assert_includes good_news, "reached both"
  end

  # --- a name nobody gave a colour is a cosmetic problem, not a crash ---

  def test_a_severity_with_no_colour_prints_the_line_plainly
    line = colored { |printer| printer.puts("something happened", severity: :unnamed) }

    assert_equal "something happened\n", line
  end

  def test_a_tree_row_with_no_colour_prints_plainly
    row = colored { |printer| printer.cost_line("update_ball", "12%", severity: :unnamed) }

    assert_includes row, "update_ball"
    refute_includes row, "\e[", "an unknown name leaves the row alone rather than killing the report"
  end

  # ...and the drift guard that would have caught this one at its source. Two vocabularies
  # use the word severity — the colours below, and a guardrail finding's own warning/error —
  # so a name that is neither is a mistake wherever it was written.
  GUARDRAIL_SEVERITIES = %i[warning error].freeze

  def test_every_severity_the_library_passes_is_one_something_understands
    passed = Dir[File.expand_path("../../../lib/**/*.rb", __dir__)].flat_map do |path|
      File.read(path).scan(/severity: :(\w+)/).flatten
    end.uniq.map(&:to_sym)

    refute_empty passed, "the scan itself has to find something"
    unknown = passed - RubyGBA::IR::ColorPrinter::COLORS.keys - GUARDRAIL_SEVERITIES

    assert_empty unknown, "no colour and no guardrail meaning: #{unknown.inspect}"
  end
end
