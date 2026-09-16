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

    # Run +block+ every time the timer ticks (overflows), driven by the timer itself —
    # so it runs at the timer's rate, precisely, independent of the game loop (where
    # `every`/`after` top out at the frame rate). Returns self so it chains.
    #
    #   timer(:beat, per_second: 100).on_tick { add :metronome, 1 }
    #
    # This is a low-level building block: it's the machinery higher-level features (a
    # metronome, sampled-audio playback, music timing) are meant to sit on top of, so a
    # game generally reaches for those friendlier verbs rather than an on_tick handler
    # directly. Note the handler runs "between" the game loop's steps, so if it and the
    # loop change the same variable they can race — have the handler own what it touches.
    def on_tick(&block)
      @builder.record_container(IR::Build.on_timer(@name), &block)
      self
    end

    # Stop the timer — it stops counting and freezes at its current tick count. Returns
    # self so it chains.
    def stop
      @builder.record_statement(IR::Build.timer_stop(@name))
      self
    end
  end
end
