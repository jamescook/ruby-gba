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

      # SET THE CLOCK to the date and time a game worked out — from a screen of its own that asked
      # the player, however it likes; the framework draws nothing for it. Each is a number or a
      # Value. Every reading after the next wait for the screen is that time, moving on a second a
      # second, and so is every reading after the console is turned off and on again.
      #
      # As the console's own games did it, nothing is written into the clock chip: the game's save
      # keeps how far the time set is from the chip's count, so a game that sets the clock has
      # save memory. A day past the end of its month runs into the next, and so does a month past
      # 12 into the next year, as a calendar counts. set? holds from then on, while the chip goes
      # on counting; a chip whose battery runs out loses the time set with its own.
      #
      #   now.set!(year: 2026, month: picked_month, day: picked_day, hour: 9, minute: 0, second: 0)
      def set!(year:, month:, day:, hour:, minute:, second:)
        parts = { year: year, month: month, day: day, hour: hour, minute: minute, second: second }
        @builder.set_clock(parts.transform_values { |part| Value.node_for(part) })
      end

      private

      def reading(name) = Value.new(@builder, IR::Build.clock(name))
    end
  end
end
