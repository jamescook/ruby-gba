# frozen_string_literal: true

module RubyGBA
  module DSL
    # THE DATE AND TIME, as the clock a cartridge carries keeps them. `clock` hands one back
    # (see Builder#clock), and each reading is a {Value} like any variable's:
    #
    #   now = clock
    #   (now.present? & now.set?)
    #     .then { draw_number now.hour, 40, 60, :white, digits: 2 }
    #     .else { draw_text "SET THE CLOCK", :center, 70, :white }
    #
    # Every reading in one pass of the game loop is of the same moment, so a minute cannot turn
    # over between reading the minute and the second. Where a build has no clock to read yet,
    # it answers as a cartridge without one (see IR::Clock).
    class Clock
      def initialize(builder)
        @builder = builder
      end

      # The hour, 0 to 23.
      def hour = reading(:hour)

      # The minute, 0 to 59.
      def minute = reading(:minute)

      # The second, 0 to 59.
      def second = reading(:second)

      # The year as it is written: 2026.
      def year = reading(:year)

      # The month, 1 for January to 12.
      def month = reading(:month)

      # The day of the month, 1 to 31.
      def day = reading(:day)

      # The day of the week, 0 for Sunday to 6 for Saturday.
      def weekday = reading(:weekday)

      # Whether this cartridge has a clock at all — false on most emulators unless they are told
      # it has one. Every reading above is 0 when it has none.
      def present? = Condition.new(@builder, IR::Build.clock(:present))

      # Whether the clock was ever set — false when its battery went in or ran out and it has
      # been counting up from 2000-01-01 since. Every reading above is 0 then too, so the game can
      # ask the player to set it rather than show a date that is not today.
      def set? = Condition.new(@builder, IR::Build.clock(:set))

      # SET THE CLOCK to a date and time, each a number or a {Value} the game works out — the
      # player's choice on a screen that asks, say. The readings are that moment at once, and
      # move on from it; `set?` is true from then on, and stays true the next time the game is
      # switched on. On a cartridge with no clock it does nothing, and every reading stays 0.
      #
      #   now.set_to(year: 2026, month: 10, day: year_day, hour: 9, minute: 30)
      #
      # Each is held to what a clock can keep: the year to 2000-2099, the day to the days its
      # month has. The day of the week is worked out from the date.
      def set_to(year:, month:, day:, hour:, minute:, second: 0)
        held = IR::Clock::SET_RANGES.to_h do |field, range|
          given = { year: year, month: month, day: day, hour: hour, minute: minute, second: second }.fetch(field)
          [field, number(given).clamp(range.min, range.max)]
        end
        held[:day] = held[:day].clamp(1, days_in_month(held[:year], held[:month]))
        @builder.record_clock_set(IR::Build.set_clock(**held.transform_values(&:node),
                                                      weekday: weekday_of(held).node))
        nil
      end

      private

      def number(given) = given.is_a?(Value) ? given : Value.new(@builder, Value.node_for(given))

      # As a number, 1 when the two are equal and 0 when not.
      def equal(a, b) = Value.new(@builder, IR::Build.binop(:==, a.node, Value.node_for(b)))

      # How many days +month+ of +year+ has. The months alternate thirty-one and thirty from
      # January, starting again at August, which is what the bit test says; February takes two
      # off that, or one in a leap year. Every fourth year between 2000 and 2099 is one.
      def days_in_month(year, month)
        feb = equal(month, 2)
        leap = equal(year % 4, 0)
        ((month + (month >> 3)) & 1) + 30 - (feb * (leap * -1 + 2))
      end

      # THE DAY OF THE WEEK of a date, 0 for Sunday: Zeller's way of counting, which starts each
      # year in March so that February's odd length comes last, where it moves nothing after it.
      # January and February are then the thirteenth and fourteenth months of the year before.
      def weekday_of(held)
        early = (held[:month] * -1 + 14) / 12 # 1 for January and February, 0 after
        year = held[:year] - early
        month = held[:month] + (early * 12) - 2 # 1 for March ... 12 for February
        (held[:day] + year + (year / 4) - (year / 100) + (year / 400) + ((month * 31) / 12)) % 7
      end

      def reading(name) = Value.new(@builder, IR::Build.clock(name))
    end
  end
end
