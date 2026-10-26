# frozen_string_literal: true

module VBlank
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

      # WHAT A GAME CAN SET THE CLOCK TO, each held to its range before it reaches any backend, so
      # that every one is given the same date. The years are the ones a clock keeps: two digits
      # of them, from 2000. A day past the end of its month is held to the last day of it as well
      # (see DSL::Clock#set_to), so no backend is asked to keep a date that does not exist.
      SET_RANGES = Ractor.make_shareable({ year: 2000..2099, month: 1..12, day: 1..31,
                                           hour: 0..23, minute: 0..59, second: 0..59 })
      SET_PARTS = SET_RANGES.keys.freeze

      # A TIME THE GAME SETS IS KEPT AS HOW FAR IT IS FROM THE CLOCK'S OWN, and every reading has
      # that added on; the clock itself is left as it is, since where it comes from is a
      # backend's own business and not every source of the time can be changed. Kept in two of
      # the game's own saved numbers, so it is there the next time the game is switched on, on
      # every backend alike.
      #
      # IN TWO PARTS, whole days and the seconds left over (0 up to a day), because a century of
      # seconds is more than one number holds. Every backend works the parts out the same way, so
      # a backend checked against another reads the same two numbers.
      OFFSET_DAYS = :__clock_offset_days
      OFFSET_SECONDS = :__clock_offset_seconds
      OFFSETS = [OFFSET_DAYS, OFFSET_SECONDS].freeze
      SECONDS_A_DAY = 86_400

      module_function

      # Whether +program+ ever sets the clock, which is when a backend adds the offset on.
      def sets_clock?(program) = program.walk.any? { |node| node.kind == :set_clock }

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

      # A CHIP THAT KEEPS NO DATE (Console::Description#clock_keeps_date), the Color's, counts only
      # the days and the time of day since it started. Its own time is taken as that many days on
      # from 1 January 2000, so a time the game sets is kept as how far it is from that, as on
      # every clock. A test's chip of that kind starts counting on the day +started+ names; this
      # is its own time at +time+.
      #
      # With no date of its own to give, it reads as never set until the game sets it: every
      # reading is 0 until there is an offset to add (see #undated_set?).
      def undated(time, started)
        days = (Time.utc(time.year, time.month, time.day) - Time.utc(started.year, started.month, started.day)) / SECONDS_A_DAY
        Time.utc(2000, 1, 1, time.hour, time.min, time.sec + time.subsec) + (days.round * SECONDS_A_DAY)
      end

      # Whether a chip that keeps no date reads as set: it counts on (+running+, its own answer)
      # and the game set a time on it, which is an offset of anything but nought.
      def undated_set?(running, offset_days, offset_seconds) = running && !(offset_days.zero? && offset_seconds.zero?)
    end
  end
end
