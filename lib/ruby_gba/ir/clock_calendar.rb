# frozen_string_literal: true

module RubyGBA
  module IR
    # THE CALENDAR IN WHOLE-NUMBER STEPS, for adding a time the game set to a clock chip's
    # reading on a cartridge (Backends::GBA::ClockChip#emit_add_offset_routine, and the Color's
    # Backends::GBC::Lowering::Clock). Neither console has a calendar of its own, so the date is
    # turned into a count of days, the offset added, and the count turned back into a date —
    # written as the program's own statements, which a lowering then lowers like any others.
    #
    # THE COUNT STARTS ON 1 MARCH 1600. From a March, so that February, the month whose length
    # changes, comes at the end of each year, where it moves no day after it; and from 1600,
    # the start of a 400-year cycle, the length after which the leap years repeat exactly —
    # every fourth year, but not every hundredth, but every four hundredth — and early enough
    # that every date a clock reads counts up from nought, so every divide rounds the way a
    # calendar needs. The other backends use their language's own calendar and agree with
    # this one (see test_clock_calendar.rb).
    module ClockCalendar
      FROM = 1600
      STARTS_ON = 3 # 1 March 1600 was a Wednesday
      DAYS_A_CYCLE = 146_097 # four hundred years

      # The day number of 1 January 2000, which a chip that keeps no date counts its days from
      # (IR::Clock.undated): a cycle to 1 March 2000, less January and February of that leap year.
      DAY_NUMBER_OF_2000 = DAYS_A_CYCLE - 31 - 29

      module_function

      # The day number of a date, from three value nodes.
      def day_number(year, month, day)
        early = binary(:/, binary(:-, number(14), month), number(12)) # 1 for January and February, 0 after
        years = binary(:-, binary(:-, year, early), number(FROM))
        cycles = binary(:/, years, number(400))
        of_cycle = binary(:-, years, binary(:*, cycles, number(400)))
        months = binary(:-, binary(:+, month, binary(:*, early, number(12))), number(3)) # 0 for March ... 11 for February
        sum(binary(:*, cycles, number(DAYS_A_CYCLE)), days_before_year(of_cycle), month_start(months), day, number(-1))
      end

      # Statements setting +into+'s :year, :month, :day and :weekday variables from the day
      # number in the variable +days+, working through +scratch+'s :cycles, :of_cycle, :years,
      # :into and :months.
      def date_of_day_number(days, into:, scratch:)
        read = ->(part) { Build.var_ref(scratch.fetch(part)) }
        days_node = Build.var_ref(days)
        of_cycle = read[:of_cycle]
        late = binary(:/, read[:months], number(10)) # 1 for January and February, which end the year before
        [
          Build.set(scratch[:cycles], binary(:/, days_node, number(DAYS_A_CYCLE))),
          Build.set(scratch[:of_cycle], binary(:-, days_node, binary(:*, read[:cycles], number(DAYS_A_CYCLE)))),
          # The years into the cycle: the days, less a day for each leap day before them, over 365.
          Build.set(scratch[:years], binary(:/, sum(of_cycle, binary(:-, number(0), binary(:/, of_cycle, number(1460))),
                                                    binary(:/, of_cycle, number(36_524)),
                                                    binary(:-, number(0), binary(:/, of_cycle, number(146_096)))),
                                            number(365))),
          Build.set(scratch[:into], binary(:-, of_cycle, days_before_year(read[:years]))),
          Build.set(scratch[:months], binary(:/, binary(:+, binary(:*, read[:into], number(5)), number(2)), number(153))),
          Build.set(into[:day], binary(:+, binary(:-, read[:into], month_start(read[:months])), number(1))),
          Build.set(into[:month], binary(:-, binary(:+, read[:months], number(3)), binary(:*, late, number(12)))),
          Build.set(into[:year], sum(read[:years], binary(:*, read[:cycles], number(400)), number(FROM), late)),
          Build.set(into[:weekday], binary(:%, binary(:+, days_node, number(STARTS_ON)), number(7))),
        ]
      end

      # The seconds into the day of three value nodes.
      def seconds_into_day(hour, minute, second)
        sum(binary(:*, hour, number(3600)), binary(:*, minute, number(60)), second)
      end

      # The days in the years of a cycle before +years+ of it: 365 each, and a leap day for
      # every fourth but not every hundredth.
      def days_before_year(years)
        sum(binary(:*, years, number(365)), binary(:/, years, number(4)), binary(:-, number(0), binary(:/, years, number(100))))
      end

      # The days from 1 March to the first of a month counted from March as 0: the months from
      # March run thirty-one, thirty, thirty-one, thirty, thirty-one, which is 153 days in five.
      def month_start(months) = binary(:/, binary(:+, binary(:*, months, number(153)), number(2)), number(5))

      def binary(operator, lhs, rhs) = Build.binop(operator, lhs, rhs)
      def number(value) = Build.int(value)
      def sum(*terms) = terms.reduce { |total, term| binary(:+, total, term) }
    end
  end
end
