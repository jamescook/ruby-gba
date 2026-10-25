# frozen_string_literal: true

module RubyGBA
  module IR
    # THE DATE AND TIME A GAME READS, as every backend answers it. Where the time comes from is
    # each backend's own business; what a game can ask, and what it is told when there is no
    # time to give, is a contract they all keep the same way, so it lives here rather than in
    # any one of them — the way the button names do.
    module Clock
      # What a game can read, each a whole number: the hour (0-23), the minute, the second, the
      # year as written (2026), the month (1-12), the day of the month (1-31) and the day of the
      # week (0 for Sunday to 6 for Saturday)...
      TIME = %i[hour minute second year month day weekday].freeze

      # ...and the two questions a game asks before it shows any of them, each 1 or 0: whether
      # there is a clock at all, and whether it was ever set.
      #
      # EVERY READING IS 0 WHEN EITHER ANSWER IS 0. A game that forgets to ask shows zeros, which
      # look wrong, rather than a date that looks right and is not.
      QUESTIONS = %i[present set].freeze

      READINGS = (TIME + QUESTIONS).freeze

      # WHAT A GAME CAN SET THE CLOCK TO, each held to its range before it reaches any backend so
      # that every one is given the same date. The years are the ones a clock chip can hold: it
      # keeps two digits, and counts from 2000. A day past the end of its month is held to the
      # last day of it as well (see DSL::Clock#set_to), so nothing is asked to keep a date that
      # does not exist.
      SET_RANGES = Ractor.make_shareable({ year: 2000..2099, month: 1..12, day: 1..31,
                                           hour: 0..23, minute: 0..59, second: 0..59 })

      # A TIME THE GAME SETS IS KEPT AS HOW FAR IT IS FROM THE CLOCK'S OWN, and every reading has
      # that added on. The clock itself is never written: an emulator keeps the time its own
      # clock says whatever a cartridge tells it, and a computer's or a browser's clock is not
      # the game's to change. Kept as a game's own saved numbers, so it is there the next time
      # the game is switched on, on every backend alike.
      #
      # IN TWO PARTS, whole days and the seconds left over (0 up to a day), because a hundred
      # years of seconds is more than one number holds. Every backend works the parts out the
      # same way, so a backend checked against another reads the same two numbers.
      OFFSET_DAYS = :__clock_offset_days
      OFFSET_SECONDS = :__clock_offset_seconds
      SECONDS_A_DAY = 86_400

      # THE CALENDAR IN WHOLE-NUMBER STEPS, as program a backend with no calendar of its own can
      # run: a date as the number of days since 1 March 1996, and back. Counting from a March
      # puts February, the month whose length changes, at the end of each year, where it moves
      # no day after it; and from 1996, so that every date a clock can hold counts up from
      # nought and every divide rounds the way a calendar needs. Every fourth year is a leap
      # year, which is true of every year from 2000 to 2099.
      CALENDAR_FROM = 1996
      CALENDAR_STARTS_ON = 5 # 1 March 1996 was a Friday

      module_function

      # The day number of a date, from three value nodes.
      def day_number(year, month, day)
        early = binary(:/, binary(:-, number(14), month), number(12)) # 1 for January and February, 0 after
        years = binary(:-, binary(:-, year, early), number(CALENDAR_FROM))
        months = binary(:-, binary(:+, month, binary(:*, early, number(12))), number(3)) # 0 for March ... 11 for February
        sum(binary(:*, years, number(365)), binary(:/, years, number(4)),
            month_start(months), day, number(-1))
      end

      # Statements setting +into+'s :year, :month, :day and :weekday variables from the day
      # number in the variable +days+, working through +scratch+'s :years, :into and :months.
      def date_of_day_number(days, into:, scratch:)
        days = Build.var_ref(days)
        years = Build.var_ref(scratch[:years])
        into_year = Build.var_ref(scratch[:into])
        months = Build.var_ref(scratch[:months])
        late = binary(:/, months, number(10)) # 1 for January and February, which end the year before
        [
          Build.set(scratch[:years], binary(:/, binary(:+, binary(:*, days, number(4)), number(3)), number(1461))),
          Build.set(scratch[:into], binary(:-, days, binary(:+, binary(:*, years, number(365)), binary(:/, years, number(4))))),
          Build.set(scratch[:months], binary(:/, binary(:+, binary(:*, into_year, number(5)), number(2)), number(153))),
          Build.set(into[:day], binary(:+, binary(:-, into_year, month_start(months)), number(1))),
          Build.set(into[:month], binary(:-, binary(:+, months, number(3)), binary(:*, late, number(12)))),
          Build.set(into[:year], sum(years, number(CALENDAR_FROM), late)),
          Build.set(into[:weekday], binary(:%, binary(:+, days, number(CALENDAR_STARTS_ON)), number(7))),
        ]
      end

      # The seconds into the day of three value nodes.
      def seconds_into_day(hour, minute, second)
        sum(binary(:*, hour, number(3600)), binary(:*, minute, number(60)), second)
      end

      # The days from 1 March to the first of a month counted from March as 0: the months from
      # March run thirty-one, thirty, thirty-one, thirty, thirty-one, which is 153 days in five.
      def month_start(months) = binary(:/, binary(:+, binary(:*, months, number(153)), number(2)), number(5))

      def binary(operator, lhs, rhs) = Build.binop(operator, lhs, rhs)
      def number(value) = Build.int(value)
      def sum(*terms) = terms.reduce { |total, term| binary(:+, total, term) }

      # +reading+ of a clock at +time+ — a Time, or nil for no clock at all — that was set when
      # +set+ is true.
      #
      # The time is read as the date and the hour it SAYS, with no time zone: a clock holds the
      # local time it was set to and moves one second a second, through a change to summer time
      # and out of one. So a Time a test gives is taken at its word, and moving it on never makes
      # an hour appear or vanish.
      def reading(reading, time, set:)
        return 0 unless time
        return 1 if reading == :present
        return 0 unless set

        case reading
        when :set then 1
        when :weekday then time.wday
        when :minute then time.min
        when :second then time.sec
        else time.public_send(reading)
        end
      end

      # +time+ moved on by +seconds+ (a Rational), keeping the date and the hour it says: worked
      # out as if no place had summer time, which is how a clock counts.
      def moved_on(time, seconds)
        Time.utc(time.year, time.month, time.day, time.hour, time.min, time.sec + time.subsec) + seconds
      end
    end
  end
end
