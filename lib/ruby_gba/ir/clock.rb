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

      module_function

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
