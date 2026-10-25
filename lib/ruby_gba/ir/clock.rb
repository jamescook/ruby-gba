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

      # THE CHIP'S COUNT, which a game never reads: the framework reads it to keep a clock the game
      # set (Builder::Clocks). The whole days since 2000-01-01 and the seconds into the day, as the
      # chip counts them whatever date it says — a chip whose battery ran out counts from
      # 2000-01-01, as every chip starts — and 1 when it has counted on since the console was last
      # on, which a chip whose battery ran out has not. With no chip, each is 0.
      #
      # Retail games kept their clock this way on both consoles. Pokemon Emerald never writes a
      # date into the Advance's chip: its save keeps how far the time the player set is from the
      # chip's count. Pokemon Crystal does the same on the Color, whose chip counts days and keeps
      # no date at all.
      #
      # A CHIP THAT KEEPS NO DATE (Console::Description#clock_keeps_date) counts its days from
      # whenever it started, not from 2000-01-01, and has no date or time to give a game that never
      # set one: every TIME reading of it is 0, and so is set?, until the game sets the clock. A
      # test's chip of that kind starts counting on the day it names, at the time of day it names.
      COUNT = %i[days seconds counting].freeze

      READINGS = (TIME + QUESTIONS + COUNT).freeze

      # A GAME THAT SETS THE CLOCK reads a number of the framework's for each of its readings and
      # for set?, worked out once a pass from the chip's count and the time it set, by the
      # framework's two routines (Builder::Clocks). A fact about the program, so a check reading it
      # (Guardrails::Checks::ClockNeverAsked) knows those numbers for the readings they are.
      SHOWN = (TIME + [:set]).to_h { |reading| [reading, :"__clock_shown_#{reading}"] }.freeze
      ROUTINES = %i[__clock_readings __clock_at_power_on].freeze

      # ...and what it keeps in its save: how far the time set is from the chip's count, in days
      # and in seconds, and whether it set one — a fact a lowering reads too, since a chip that can
      # count only so many days has whole days moved out of it into this record before it fills.
      RECORD = %i[days seconds set].to_h { |part| [part, :"__clock_record_#{part}"] }.freeze

      # The first day the count starts from, and the seconds in a day.
      EPOCH = Time.utc(2000, 1, 1).freeze
      DAY = 86_400

      module_function

      # +reading+ of a clock at +time+ — a Time, or nil for no clock at all — that was set when
      # +set+ is true. A clock that keeps no date (+dated+ false) counts its days from the date
      # it +started+ at.
      #
      # The time is read as the date and the hour it SAYS, with no time zone: a clock holds the
      # local time it was set to and moves one second a second, through a change to summer time
      # and out of one. So a Time a test gives is taken at its word, and moving it on never makes
      # an hour appear or vanish.
      def reading(reading, time, set:, started: time, dated: true)
        return 0 unless time
        return 1 if reading == :present
        return counted(reading, time, set, dated ? EPOCH : started) if COUNT.include?(reading)
        return 0 unless set && dated

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

      # The chip's count at +time+: its days since the date of +from+, its seconds, or whether it
      # counted on (+set+).
      def counted(reading, time, set, from)
        case reading
        when :days then (Time.utc(time.year, time.month, time.day) - Time.utc(from.year, from.month, from.day)).div(DAY)
        when :seconds then (time.hour * 3600) + (time.min * 60) + time.sec
        else set ? 1 : 0
        end
      end

      # THE CALENDAR, AS A PROGRAM EVERY BACKEND RUNS: the days since 2000-01-01 of the date
      # +year+, +month+ and +day+, as an IR value. Each argument makes a fresh node every time it
      # is called, since a node has one place in the tree. The month is 1 to 12 and the day
      # counts on from the 1st, so a day past the end of its month is a day of the next.
      #
      # It counts from a year that starts in March, which puts the 29th of February last: then a
      # month's first day is (153 * months since March + 2) / 5 into the year, and a year is 365
      # days, one more every 4 years, one less every 100 and one more every 400, the 400 years
      # always 146097 days. (Howard Hinnant's days_from_civil.)
      def days_from_civil(year, month, day)
        b = Build
        march = -> { b.binop(:<=, month.call, b.int(2)) } # 1 for January and February
        y = -> { b.binop(:-, year.call, march.call) }
        era = -> { b.binop(:/, y.call, b.int(400)) }
        yoe = -> { b.binop(:-, y.call, b.binop(:*, era.call, b.int(400))) }
        since_march = b.binop(:-, b.binop(:+, month.call, b.int(9)), b.binop(:*, b.int(12), b.binop(:>, month.call, b.int(2))))
        doy = b.binop(:+, b.binop(:/, b.binop(:+, b.binop(:*, b.int(153), since_march), b.int(2)), b.int(5)),
                      b.binop(:-, day.call, b.int(1)))
        doe = b.binop(:+, b.binop(:-, b.binop(:+, b.binop(:*, yoe.call, b.int(365)), b.binop(:/, yoe.call, b.int(4))),
                                  b.binop(:/, yoe.call, b.int(100))), doy)
        b.binop(:+, b.binop(:*, era.call, b.int(146_097)), b.binop(:-, doe, b.int(DAYS_TO_EPOCH)))
      end

      # From the first day of that count, 0000-03-01, to 2000-01-01.
      DAYS_TO_EPOCH = 730_425

      # THE DATE OF +days+ since 2000-01-01, the other way: statements that set +into+[:year],
      # [:month], [:day] and [:weekday] (variable names), working in the variables +work+ names
      # (:era, :doe, :yoe, :doy, :mp). +days+ makes a fresh node each call. 2000-01-01 was a
      # Saturday, day 6 of the week. (Howard Hinnant's civil_from_days.)
      def civil_from_days(days, into:, work:)
        b = Build
        v = ->(name) { b.var_ref(work.fetch(name)) }
        z = -> { b.binop(:+, days.call, b.int(DAYS_TO_EPOCH)) }
        [b.set(into.fetch(:weekday), b.binop(:%, b.binop(:+, days.call, b.int(6)), b.int(7))),
         b.set(work.fetch(:era), b.binop(:/, z.call, b.int(146_097))),
         b.set(work.fetch(:doe), b.binop(:-, z.call, b.binop(:*, v.call(:era), b.int(146_097)))),
         b.set(work.fetch(:yoe),
               b.binop(:/, b.binop(:-, b.binop(:+, b.binop(:-, v.call(:doe), b.binop(:/, v.call(:doe), b.int(1460))),
                                                b.binop(:/, v.call(:doe), b.int(36_524))),
                                   b.binop(:/, v.call(:doe), b.int(146_096))), b.int(365))),
         b.set(work.fetch(:doy),
               b.binop(:-, v.call(:doe), b.binop(:-, b.binop(:+, b.binop(:*, b.int(365), v.call(:yoe)),
                                                            b.binop(:/, v.call(:yoe), b.int(4))),
                                                b.binop(:/, v.call(:yoe), b.int(100))))),
         b.set(work.fetch(:mp), b.binop(:/, b.binop(:+, b.binop(:*, b.int(5), v.call(:doy)), b.int(2)), b.int(153))),
         b.set(into.fetch(:day), b.binop(:+, b.binop(:-, v.call(:doy), b.binop(:/, b.binop(:+, b.binop(:*, b.int(153), v.call(:mp)),
                                                                                         b.int(2)), b.int(5))), b.int(1))),
         b.set(into.fetch(:month), b.binop(:-, b.binop(:+, v.call(:mp), b.int(3)),
                                           b.binop(:*, b.int(12), b.binop(:>=, v.call(:mp), b.int(10))))),
         b.set(into.fetch(:year), b.binop(:+, b.binop(:+, v.call(:yoe), b.binop(:*, v.call(:era), b.int(400))),
                                          b.binop(:<=, b.var_ref(into.fetch(:month)), b.int(2))))]
      end
    end
  end
end
