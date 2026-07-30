# frozen_string_literal: true

module RubyGBA
  # A handle to a hardware timer: a counter that runs at a chosen rate, for timed work
  # (and, later, to clock sampled audio). `timer :beat, per_second: 4` hands one back —
  # it ticks four times a second. See Builder#timer.
  #
  #   beat = timer :beat, per_second: 4
  #   (beat.ticks > last).then { ... }   # ticks climbs 4 times a second
  #   beat.stop
  #
  # `ticks` is how many times it has ticked (overflowed) since it started — a {Value},
  # so it reads and compares like any other. The framework manages the hardware behind
  # it: the rate becomes a prescaler and reload, and reading the count is handled for you.
  class Timer
    # Built by Builder#timer, which starts the timer and reserves its hardware.
    def initialize(builder, name)
      @builder = builder
      @name = name
    end

    # @return [Symbol] the timer's name
    attr_reader :name

    # How many times the timer has ticked since it started, as a {Value} (wraps at
    # 65536). Reading this reserves a little extra hardware to keep the count; a timer
    # you never read costs less.
    def ticks
      Value.new(@builder, IR::Build.timer_ticks(@name))
    end

    # Stop the timer — it stops counting and freezes at its current tick count. Returns
    # self so it chains.
    def stop
      @builder.record_statement(IR::Build.timer_stop(@name))
      self
    end
  end
end
