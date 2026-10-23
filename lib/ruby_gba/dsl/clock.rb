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

      private

      def reading(name) = Value.new(@builder, IR::Build.clock(name))
    end
  end
end
