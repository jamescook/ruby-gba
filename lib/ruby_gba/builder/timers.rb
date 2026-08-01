# frozen_string_literal: true

module RubyGBA
  class Builder
    # The hardware-timer verb: `timer` — start a counter running at a chosen rate and
    # hand back a {Timer} handle to read (`.ticks`) and stop it. A concern of {Builder},
    # mixed in so `timer` stays a flat DSL verb.
    module Timers
      # Start a hardware timer named +name+ that ticks +per_second+ times a second.
      # Returns a {Timer} handle. Calling `timer` again with the same name restarts it
      # (its tick count resets to zero).
      #
      #   beat = timer :beat, per_second: 2   # ticks twice a second
      #
      # For frame-paced gameplay timing, reach for `every` / `after` instead; a hardware
      # timer is for precise, free-running timing that keeps counting on its own.
      #
      # @param name [Symbol] the timer's name
      # @param per_second [Integer] how many times a second it ticks (a positive whole number)
      # @return [Timer]
      def timer(name, per_second:)
        raise ArgumentError, "A timer name must be a Symbol. Got #{name.inspect}. Use a name like :beat." unless name.is_a?(Symbol)
        unless per_second.is_a?(Integer) && per_second.positive?
          raise ArgumentError,
                "timer :#{name} needs per_second to be a positive whole number of ticks a second. " \
                "Got #{per_second.inspect}. " \
                "For slower or fractional timing, use `every` or `after` by frames or seconds."
        end

        # The IR speaks in Hz (overflows per second) — the same number, named for what it
        # is one layer down.
        record(IR::Build.timer_start(name, per_second))
        Timer.new(self, name)
      end
    end
  end
end
