# frozen_string_literal: true

module VBlank
  class Builder
    # The clock verb: `clock` — the date and time, as the clock a cartridge carries keeps them.
    # A concern of {Builder}, mixed in so `clock` stays a flat DSL verb.
    module Clocks
      # The cartridge's clock, as a {DSL::Clock} whose readings are numbers like any variable's:
      # `clock.hour`, `.minute`, `.second`, `.year`, `.month`, `.day` and `.weekday`, and the
      # tests `clock.present?` and `clock.set?`.
      #
      #   now = clock
      #   draw_number now.minute, 60, 60, :white, digits: 2
      #
      # @return [DSL::Clock]
      def clock = DSL::Clock.new(self)

      # The hook behind `clock.set_to` (see DSL::Clock#set_to), which hands it the statement
      # that sets the clock. How far the time set is from the clock's own is kept in two saved
      # numbers (see IR::Clock::OFFSET_DAYS), saved like any `save_var` the moment they change,
      # so they are there at the next power-on.
      def record_clock_set(node)
        IR::Clock::OFFSETS.each { |name| save_var(name, 0) }
        record(node)
        IR::Clock::OFFSETS.each { |name| mirror_save(name) }
      end
    end
  end
end
