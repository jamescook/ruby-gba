# frozen_string_literal: true

module RubyGBA
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
    end
  end
end
