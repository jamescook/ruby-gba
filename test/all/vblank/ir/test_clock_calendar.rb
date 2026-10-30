# frozen_string_literal: true

require "test_helper"

require "date"

# THE CALENDAR A CARTRIDGE ADDS A TIME THE GAME SET WITH (IR::ClockCalendar), written as the
# program's own statements. Played on the interpreter here, which runs those statements exactly
# as each cartridge's lowering of them does, and held to Ruby's own calendar: the first and last
# days of every month, across the century turns where the leap years change.
class TestClockCalendar < Minitest::Test
  Calendar = VBlank::IR::ClockCalendar
  B = VBlank::IR::Build

  INTO = %i[year month day weekday].to_h { |part| [part, :"out_#{part}"] }.freeze
  SCRATCH = %i[cycles of_cycle years into months].to_h { |part| [part, :"work_#{part}"] }.freeze

  # Every month's first and last day of the years either side of 2000, 2100 and 2200, and of a
  # year in between.
  DATES = [1999, 2000, 2001, 2004, 2099, 2100, 2101, 2104, 2199, 2200, 2201, 2299].flat_map do |year|
    (1..12).flat_map { |month| [Date.new(year, month, 1), Date.new(year, month, -1)] }
  end.reject { |date| date < Date.new(2000, 1, 1) }.freeze

  # The day number of +date+, and back to a date, as one run of the interpreter.
  private def round_trip(date)
    days = Calendar.day_number(B.int(date.year), B.int(date.month), B.int(date.day))
    program = B.program(B.set(:days, days), *Calendar.date_of_day_number(:days, into: INTO, scratch: SCRATCH), B.halt)
    run = Reference.new.run(program)
    [run[:days], *INTO.values.map { |name| run[name] }]
  end

  def test_every_date_comes_back_as_itself_with_its_day_of_the_week
    wrong = DATES.reject do |date|
      _, *back = round_trip(date)
      back == [date.year, date.month, date.day, date.wday]
    end

    assert_empty wrong.map(&:iso8601), "these dates should come back as themselves"
  end

  # The day numbers count days, so two dates' numbers are as far apart as the dates are: there
  # is no 29 February in 2100 or 2200, and there is one in 2000.
  def test_the_day_numbers_are_as_far_apart_as_the_dates
    first = DATES.first
    wrong = DATES.reject { |date| round_trip(date).first - round_trip(first).first == (date - first).to_i }

    assert_empty wrong.map(&:iso8601), "these dates should be as many days on as the calendar says"
  end
end
